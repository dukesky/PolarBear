# shellcheck shell=bash
# Shared settings and helpers for infrastructure/gcp/*.sh. Source it; don't run it.
#
# Every value here can be overridden from the environment, e.g.
#   PROJECT=my-project ./10-move-backend-to-internal-network.sh
# No secrets live in this file or in any script that sources it.

: "${PROJECT:=polarbear-dev-479000}"
: "${REGION:=us-west1}"                  # where the VM, its disk and the backups live
: "${ZONE:=us-west1-b}"
: "${VM:=polarbear-services}"
: "${DISK:=$VM}"                         # the boot disk has the same name as the VM
: "${VM_INTERNAL_IP:=10.138.0.2}"
: "${VM_INTERNAL_ADDRESS_NAME:=polarbear-services-internal}"
: "${VPC_NETWORK:=default}"
: "${RUN_REGION:=us-central1}"           # where Cloud Run lives
: "${RUN_SERVICE:=polarbear-backend}"
: "${RUN_SUBNET:=default}"               # the VPC_NETWORK subnet in RUN_REGION
: "${RUN_SUBNET_RANGE:=10.128.0.0/20}"   # that subnet's range; checked, not trusted
: "${PG_CONTAINER:=polarbear-postgres-1}"
: "${MEILI_CONTAINER:=polarbear-meilisearch-1}"
: "${PG_USER:=polarbear}"
: "${PG_DB:=polarbear}"
: "${DRY_RUN:=0}"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

is_dry_run() { [[ "$DRY_RUN" == "1" ]]; }

# run CMD ARGS... — runs a state-changing command, or prints it under DRY_RUN=1.
# Never pass a secret as an argument; secrets go through files (see run_shown_as).
run() {
  # Show and run the real gcloud command line, not the `gc` shorthand.
  if [[ "$1" == gc ]]; then shift; set -- gcloud --project "$PROJECT" --quiet "$@"; fi
  if is_dry_run; then
    printf 'DRY-RUN would run:' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  log "RUN: $*"
  "$@"
}

# run_shown_as "DISPLAY" CMD ARGS... — like run, but only DISPLAY is ever
# printed. Use it when an argument points at something secret-bearing.
run_shown_as() {
  local display=$1; shift
  if is_dry_run; then
    printf 'DRY-RUN would run: %s\n' "$display" >&2
    return 0
  fi
  log "RUN: $display"
  "$@"
}

gc() { gcloud --project "$PROJECT" --quiet "$@"; }

# vm_ssh 'remote command' — read-only helper for commands on the VM.
vm_ssh() {
  gcloud compute ssh "$VM" --zone "$ZONE" --project "$PROJECT" --quiet \
    --command "$1" -- -o ConnectTimeout=15 -o LogLevel=ERROR
}

require() {
  local t
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"; done
}

banner() {
  log "=== $* (project=$PROJECT, DRY_RUN=$DRY_RUN) ==="
}

# alarm TITLE LINE... — an unmissable block on stderr for things a human must act on.
alarm() {
  local title=$1; shift
  {
    printf '\n!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
    printf '!!  %s\n' "$title"
    printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
    local l; for l in "$@"; do printf '!!  %s\n' "$l"; done
    printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n\n'
  } >&2
}

# ------------------------------------------------------------------ exit handling
# One EXIT trap per script, installed when this file is sourced. It does two things:
#   1. If a recovery function is ARMED, it runs it. That happens on ANY exit
#      while armed: a `set -e` abort, an explicit `exit 1`, Ctrl-C/TERM, or a
#      crash inside a verify step. Arm it just BEFORE the first mutation and
#      disarm it once the script has verified success. A script that exits
#      while armed always exits non-zero.
#   2. Removes the temp paths registered with add_cleanup.
# Recovery functions run with `set +e`. They must attempt every step, collect
# failures, and finish with an `alarm` that says what is and is not restored.
# Under DRY_RUN=1, arm_recovery does nothing, so no recovery can fire. Recovery
# functions use `run` as well, so a dry run cannot mutate through them either way.
_RECOVERY=""
_CLEANUP=""
_DONE=0
# finish: the ONLY way a script declares success. Bash 3.2 can abort a script with a
# runtime parse/expansion error ("bad substitution") and still report exit code 0. So an
# exit 0 that did not come through finish() is treated as a failure (see _on_exit).
finish() { _DONE=1; exit 0; }
add_cleanup() { _CLEANUP="$_CLEANUP $1"; }
keep_path()   { _CLEANUP=$(printf '%s' "$_CLEANUP" | tr ' ' '\n' | { grep -vxF -- "$1" || true; } | tr '\n' ' '); }  # un-register
arm_recovery() {
  declare -F "$1" >/dev/null || die "BUG: recovery function '$1' is not defined at the point it is armed"
  if is_dry_run; then log "(dry run) would arm recovery: $1"; return 0; fi
  _RECOVERY=$1
  log "recovery armed: $1 (runs on any exit until disarmed)"
}
disarm_recovery() { if [[ -n "$_RECOVERY" ]]; then log "recovery disarmed: $_RECOVERY"; fi; _RECOVERY=""; }

_on_exit() {
  local rc=$? fn p
  trap - EXIT INT TERM
  set +e
  if [[ "$rc" == 0 && "$_DONE" != 1 ]]; then
    log "ERROR: the script stopped before reaching its end, but bash reported success; treating it as a FAILURE"
    rc=1
  fi
  if [[ -n "$_RECOVERY" ]]; then
    fn=$_RECOVERY; _RECOVERY=""
    [[ "$rc" == 0 ]] && rc=1
    log "exiting (code $rc) with recovery armed — running $fn"
    if declare -F "$fn" >/dev/null; then "$fn"
    else alarm "RECOVERY '$fn' DOES NOT EXIST — NOTHING WAS ROLLED BACK" "This is a script bug. Check production by hand now."; fi
  fi
  for p in $_CLEANUP; do rm -rf "$p"; done
  exit "$rc"
}
trap _on_exit EXIT
trap 'log "interrupted"; exit 130' INT
trap 'log "terminated"; exit 143' TERM

# ------------------------------------------------------------------ backend env values (literal OR secret ref)
# Since script 35, DATABASE_URL and MEILI_MASTER_KEY are secret references, not literals. Any check
# that needs something INSIDE such a value (e.g. the host) must go through these helpers, never
# parse the service JSON's "value" field directly. That returns nothing for a secret ref, and
# earlier code turned that into "host=None".

# backend_env_value NAME JSON_FILE: the value of env var NAME in a Cloud Run service JSON
# (spec.template.spec) or revision JSON (spec). A literal is used as is. A secretKeyRef must be
# PINNED to a version number; that exact version is read with `gcloud secrets versions access
# --out-file` (raw bytes, 0600 temp file, removed at once). The value goes to STDOUT for a pipe or
# $(...) ONLY: the function refuses to run when stdout is a terminal. It fails loudly (non-zero,
# naming the problem, never the value) if NAME is absent, unpinned (e.g. `latest`), or unreadable.
backend_env_value() {
  local name=$1 json=$2 ref s v f
  if [[ -t 1 ]]; then log "BUG: backend_env_value would print $name to a terminal; refusing"; return 2; fi
  ref=$(python3 - "$json" "$name" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
spec = d["spec"]["template"]["spec"] if "template" in d.get("spec", {}) else d["spec"]
env = {e["name"]: e for e in spec["containers"][0].get("env", [])}
e = env.get(sys.argv[2])
if e is None: print("absent")
elif "value" in e: print("literal")
else:
    r = (e.get("valueFrom") or {}).get("secretKeyRef") or {}
    print("secret %s %s" % (r.get("name", "?"), r.get("key", "?")))
PY
) || { log "ERROR: cannot parse $json for $name"; return 1; }
  case "$ref" in
    absent)  log "ERROR: env var $name is not set on the backend"; return 1 ;;
    literal)
      python3 - "$json" "$name" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
spec = d["spec"]["template"]["spec"] if "template" in d.get("spec", {}) else d["spec"]
sys.stdout.write({e["name"]: e for e in spec["containers"][0]["env"]}[sys.argv[2]]["value"])
PY
      ;;
    secret\ *)
      read -r _ s v <<< "$ref"
      if [[ ! "$v" =~ ^[0-9]+$ ]]; then
        log "ERROR: $name references secret $s version '$v', which is NOT PINNED to a number; refusing (pin it: --update-secrets $name=$s:<N>)"
        return 1
      fi
      f=$(mktemp)
      if ! gcloud --project "$PROJECT" --quiet secrets versions access "$v" --secret "$s" --out-file "$f" >/dev/null 2>&1 || [[ ! -s "$f" ]]; then
        rm -f "$f"; log "ERROR: $name references $s:$v, which could not be read (missing, disabled, destroyed, or no access)"; return 1
      fi
      cat "$f"; rm -f "$f" ;;
    *) log "ERROR: unexpected reference for $name: $ref"; return 1 ;;
  esac
}

_url_host() {  # stdin: a URL. stdout: its host. Fails on a URL without a host (never prints "None").
  python3 -c '
import sys, urllib.parse as up
h = up.urlsplit(sys.stdin.read().strip()).hostname
if not h: sys.exit("no host in the URL")
print(h)'
}

# backend_datastore_hosts: prints "<DATABASE_URL host> <MEILI_HOST host>" as the SERVING revision
# uses them. It fails loudly if any value is unreadable, or if the service template (what the next
# revision would get) disagrees with the serving revision. Only hosts are printed.
backend_datastore_hosts() {
  local d rev src db me first="" rc=0
  d=$(mktemp -d)
  if ! gcloud --project "$PROJECT" --quiet run services describe "$RUN_SERVICE" --region "$RUN_REGION" --format=json > "$d/svc.json"; then
    rm -rf "$d"; log "ERROR: cannot describe $RUN_SERVICE"; return 1
  fi
  rev=$(python3 -c '
import json, sys
t = [x for x in json.load(open(sys.argv[1]))["status"].get("traffic", []) if x.get("percent")]
print(max(t, key=lambda x: x["percent"])["revisionName"] if t else "")' "$d/svc.json")
  if [[ -z "$rev" ]] || ! gcloud --project "$PROJECT" --quiet run revisions describe "$rev" --region "$RUN_REGION" --format=json > "$d/rev.json"; then
    rm -rf "$d"; log "ERROR: cannot read the serving revision '$rev'"; return 1
  fi
  for src in rev svc; do
    db=$(backend_env_value DATABASE_URL "$d/$src.json" | _url_host) || { log "ERROR: DATABASE_URL host unreadable ($src)"; rc=1; break; }
    me=$(backend_env_value MEILI_HOST "$d/$src.json" | _url_host) || { log "ERROR: MEILI_HOST host unreadable ($src)"; rc=1; break; }
    if [[ -z "$first" ]]; then first="$db $me"
    elif [[ "$first" != "$db $me" ]]; then
      log "ERROR: serving revision $rev uses hosts '$first' but the service template has '$db $me'"; rc=1
    fi
  done
  rm -rf "$d"
  [[ "$rc" == 0 ]] || return 1
  echo "$first"
}
