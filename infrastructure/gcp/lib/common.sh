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
