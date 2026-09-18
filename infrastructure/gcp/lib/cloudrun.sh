# shellcheck shell=bash
# Cloud Run env helpers shared by 35- and 50-. Source lib/common.sh first.
# Nothing here prints an env VALUE: only names, hashes (first 16 hex), and the kind of
# each variable (literal, or which secret/version it references).

describe_service_json() {  # describe_service_json FILE: service JSON (contains values) into a 0600 file
  gc run services describe "$RUN_SERVICE" --region "$RUN_REGION" --format=json > "$1"
  chmod 600 "$1"
}

env_hashes() {  # env_hashes SERVICE_JSON: prints "NAME SHA256" per env var. A secret ref is hashed as its JSON.
  python3 - "$1" <<'PY'
import hashlib, json, sys
env = json.load(open(sys.argv[1]))["spec"]["template"]["spec"]["containers"][0].get("env", [])
for e in sorted(env, key=lambda e: e["name"]):
    v = e["value"] if "value" in e else json.dumps(e.get("valueFrom"), sort_keys=True)
    print(e["name"], hashlib.sha256(v.encode()).hexdigest())
PY
}

show_hashes() {  # show_hashes HASH_FILE LABEL
  log "$2: env var names and SHA-256 (first 16 hex shown):"
  awk '{printf "    %-20s %s\n", $1, substr($2,1,16)}' "$1" >&2
}

# env_diff BEFORE AFTER "ALLOWED NAMES": prints what differs. Returns 1 if any variable
# OUTSIDE the allowed set was changed, added or removed.
env_diff() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
b = dict(l.split() for l in open(sys.argv[1]) if l.strip())
a = dict(l.split() for l in open(sys.argv[2]) if l.strip())
allowed = set(sys.argv[3].split())
changed = sorted(k for k in a if k in b and a[k] != b[k])
added = sorted(set(a) - set(b)); removed = sorted(set(b) - set(a))
print("changed=%s added=%s removed=%s (allowed to differ: %s)" % (changed or "-", added or "-", removed or "-", sorted(allowed)), file=sys.stderr)
outside = [k for k in changed + added + removed if k not in allowed]
if outside:
    print("NOT ALLOWED to differ: %s" % outside, file=sys.stderr); sys.exit(1)
print("unchanged: %d variables byte-identical" % len([k for k in a if k in b and a[k] == b[k]]), file=sys.stderr)
PY
}

env_kind() {  # env_kind SERVICE_JSON NAME: prints literal | secret:<secret>:<version> | absent
  python3 - "$1" "$2" <<'PY'
import json, sys
env = {e["name"]: e for e in json.load(open(sys.argv[1]))["spec"]["template"]["spec"]["containers"][0].get("env", [])}
e = env.get(sys.argv[2])
if e is None: print("absent")
elif "value" in e: print("literal")
else:
    r = e.get("valueFrom", {}).get("secretKeyRef", {})
    print("secret:%s:%s" % (r.get("name", "?"), r.get("key", "?")))
PY
}

runtime_service_account() {  # the service account Cloud Run runs as (default compute SA if unset)
  local sa num
  sa=$(gc run services describe "$RUN_SERVICE" --region "$RUN_REGION" --format='value(spec.template.spec.serviceAccountName)')
  if [[ -z "$sa" ]]; then
    num=$(gc projects describe "$PROJECT" --format='value(projectNumber)')
    sa="${num}-compute@developer.gserviceaccount.com"
  fi
  echo "$sa"
}

# route_traffic_back REV: best effort, reads back. Prints a problem string (empty = OK).
route_traffic_back() {
  local rev=$1 now
  if ! run gc run services update-traffic "$RUN_SERVICE" --region "$RUN_REGION" --to-revisions "$rev=100" >/dev/null; then
    echo "gcloud run services update-traffic --to-revisions $rev=100 FAILED"; return
  fi
  now=$(serving_revision 2>/dev/null)
  if [[ "$now" != "$rev" ]]; then echo "serving revision reads back as '${now:-unknown}', not $rev"; fi
}
