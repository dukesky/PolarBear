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
    "$fn"
  fi
  for p in $_CLEANUP; do rm -rf "$p"; done
  exit "$rc"
}
trap _on_exit EXIT
trap 'log "interrupted"; exit 130' INT
trap 'log "terminated"; exit 143' TERM
