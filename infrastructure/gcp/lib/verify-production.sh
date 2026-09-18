# shellcheck shell=bash
# The production checks (brief step N4), shared by the 10-, 20- and 30- scripts.
# Source lib/common.sh first, then this file, then call:
#
#   verify_production [SINCE_RFC3339]
#
# It returns 0 only if ALL of these hold:
#   1. GET /health                                  -> 200
#   2. GET /search/?q=test&key=pb_search_bogus      -> 401   (backend can reach Postgres)
#   3. a real search with a real public search key  -> 200 with results
#                                                      (backend can reach Meilisearch)
#   4. zero ERROR-or-worse log entries from the serving revision since SINCE
#      (default: when that revision was created)
#
# It is read-only, with one exception: check 3 is a real shopper-style search,
# so it adds one row to that tenant's search analytics. Under DRY_RUN=1, check 3
# is skipped for that reason unless VERIFY_REAL_SEARCH=1.
#
# Search keys are public by design (they ship inside merchants' web pages), but
# they are still never printed: only the tenant they belong to is.

: "${VERIFY_QUERY:=test}"
: "${VERIFY_LOG_WAIT:=20}"   # seconds to let Cloud Logging catch up before check 4

backend_url() {
  gc run services describe "$RUN_SERVICE" --region "$RUN_REGION" --format='value(status.url)'
}

# The revision currently taking the most traffic.
serving_revision() {
  gc run services describe "$RUN_SERVICE" --region "$RUN_REGION" --format=json |
    python3 -c '
import json, sys
t = json.load(sys.stdin)["status"].get("traffic", [])
t = [x for x in t if x.get("percent")]
print(max(t, key=lambda x: x["percent"])["revisionName"] if t else "")'
}

_http_code() {  # _http_code URL [curl args...] -> prints the status code only
  local url=$1; shift
  local code
  # curl prints 000 itself when it cannot connect; `|| true` keeps set -e from firing.
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$@" "$url" 2>/dev/null) || true
  echo "${code:-000}"
}

verify_production() {
  local since=${1:-} url rev code failed=0
  url=$(backend_url) || { log "verify: cannot read backend URL"; return 1; }
  rev=$(serving_revision) || { log "verify: cannot read serving revision"; return 1; }
  [[ -n "$url" && -n "$rev" ]] || { log "verify: empty backend URL or revision"; return 1; }
  log "verify: backend=$url serving revision=$rev"

  # 1. health
  code=$(_http_code "$url/health")
  if [[ "$code" == 200 ]]; then log "verify: [PASS] GET /health -> 200"
  else log "verify: [FAIL] GET /health -> $code (want 200)"; failed=1; fi

  # 2. bogus key must be rejected by a DB lookup
  code=$(_http_code "$url/search/?q=test&key=pb_search_bogus")
  if [[ "$code" == 401 ]]; then log "verify: [PASS] bogus search key -> 401 (Postgres path OK)"
  else log "verify: [FAIL] bogus search key -> $code (want 401)"; failed=1; fi

  # 3. real search with a real key
  if is_dry_run && [[ "${VERIFY_REAL_SEARCH:-0}" != 1 ]]; then
    log "verify: [SKIP] real search (DRY_RUN: it would write a search-analytics row; set VERIFY_REAL_SEARCH=1 to include it)"
  else
    if ! _verify_real_search "$url"; then failed=1; fi
  fi

  # 4. no ERROR logs from the serving revision
  if [[ -z "$since" ]]; then
    since=$(gc run revisions describe "$rev" --region "$RUN_REGION" \
              --format='value(metadata.creationTimestamp)') || since=""
  fi
  if [[ -z "$since" ]]; then
    log "verify: [FAIL] could not work out the log window start"; failed=1
  else
    if ! is_dry_run && [[ "$VERIFY_LOG_WAIT" -gt 0 ]]; then
      log "verify: waiting ${VERIFY_LOG_WAIT}s for Cloud Logging to catch up"
      sleep "$VERIFY_LOG_WAIT"
    fi
    local filter entries n
    filter="resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$RUN_SERVICE\" AND resource.labels.revision_name=\"$rev\" AND severity>=ERROR AND timestamp>=\"$since\""
    # Only timestamp and severity are printed: a log payload could contain anything.
    if entries=$(gc logging read "$filter" --limit 50 --format='value(timestamp,severity)'); then
      n=$(printf '%s' "$entries" | grep -c . || true)
      if [[ "$n" == 0 ]]; then log "verify: [PASS] 0 ERROR log entries from $rev since $since"
      else
        log "verify: [FAIL] $n ERROR log entries from $rev since $since:"
        printf '%s\n' "$entries" | sed 's/^/    /' >&2
        log "verify:        inspect with: gcloud logging read '$filter' --project $PROJECT --limit 10"
        failed=1
      fi
    else
      log "verify: [FAIL] could not read logs"; failed=1
    fi
  fi

  if [[ "$failed" == 0 ]]; then log "verify: ALL CHECKS PASSED"; return 0; fi
  log "verify: CHECKS FAILED"; return 1
}

# Reads public search keys from api_keys on the VM and searches with each until
# one returns results. Keys stay in this shell's memory; they are never printed.
_verify_real_search() {
  local url=$1 rows tenant key body code total tmp
  rows=$(vm_ssh "sudo docker exec $PG_CONTAINER psql -U $PG_USER -d $PG_DB -AtF ' ' -c \
    \"select tenant_id, plaintext from api_keys where kind='search' and plaintext is not null order by created_at\"") || {
    log "verify: [FAIL] could not read search keys over SSH"; return 1; }
  [[ -n "$rows" ]] || { log "verify: [FAIL] no search keys found in api_keys"; return 1; }

  tmp=$(mktemp) && chmod 600 "$tmp"
  while read -r tenant key; do
    [[ -n "$key" ]] || continue
    # Header, not ?key=, so the key does not end up in request-URL logs.
    code=$(curl -sS -o "$tmp" -w '%{http_code}' --max-time 30 -G \
             --data-urlencode "q=$VERIFY_QUERY" --data-urlencode "limit=5" \
             -H "X-PolarBear-Key: $key" "$url/search/" 2>/dev/null) || true
    code=${code:-000}
    body=$(cat "$tmp")
    total=$(printf '%s' "$body" | python3 -c 'import json,sys
try: print(int(json.load(sys.stdin).get("total", 0)))
except Exception: print(-1)')
    if [[ "$code" == 200 && "$total" -gt 0 ]]; then
      log "verify: [PASS] real search for tenant $tenant -> 200 with $total results (Meilisearch path OK)"
      rm -f "$tmp"; return 0
    fi
    log "verify:        tenant $tenant -> HTTP $code, total=$total; trying the next tenant"
  done <<< "$rows"
  rm -f "$tmp"
  log "verify: [FAIL] no tenant's search key returned 200 with results for q='$VERIFY_QUERY'"
  return 1
}
