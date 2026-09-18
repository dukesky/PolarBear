#!/usr/bin/env bash
# 20 — Close Postgres and Meilisearch to the internet  (brief step N5)
#
# CHANGES
#   Firewall rules allow-postgres (tcp:5432) and allow-meilisearch (tcp:7700):
#   source ranges 0.0.0.0/0 -> the us-central1 subnet only (10.128.0.0/20),
#   which is where Cloud Run's Direct VPC egress traffic comes from.
#
# VERIFIES
#   Before: the backend already talks to the VM's internal IP (run
#   10-move-backend-to-internal-network.sh first). Otherwise this would cut
#   production off, so the script refuses.
#   After: the N4 production checks (lib/verify-production.sh), then a TCP
#   connect from THIS machine to the VM's external IP on 5432 and 7700, which
#   must fail.
#
# ROLLS BACK
#   Recovery is armed before the first rule update. ANY exit before the N4
#   checks pass (a failed check, a crashed call, a set -e abort, Ctrl-C) puts
#   each rule's previous source ranges back. It tries every rule even if one
#   fails, reads them back, prints a banner saying which rules are and are
#   not restored plus the manual commands, and exits non-zero. It does NOT reopen the ports if only the final probe fails.
#   That would mean the ports are still open, and reopening them further
#   would not help.
#
# SAFE TO RE-RUN: rules already narrowed are left alone.
# SSH (default-allow-ssh) and the VM's external IP are not touched.
#
# Usage:  DRY_RUN=1 ./20-close-public-database-ports.sh
#         ./20-close-public-database-ports.sh
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/verify-production.sh
source "$HERE/lib/verify-production.sh"

: "${FIREWALL_RULES:=allow-postgres allow-meilisearch}"
: "${PROBE_PORTS:=5432 7700}"
: "${PROBE_TIMEOUT:=5}"

require gcloud python3 curl
banner "20: narrow $FIREWALL_RULES to $RUN_SUBNET_RANGE"

# ---------------------------------------------------------------- preflight
range=$(gc compute networks subnets describe "$RUN_SUBNET" --region "$RUN_REGION" --format='value(ipCidrRange)')
[[ "$range" == "$RUN_SUBNET_RANGE" ]] ||
  die "subnet $RUN_SUBNET in $RUN_REGION is $range, script expects $RUN_SUBNET_RANGE"

hosts=$(gc run services describe "$RUN_SERVICE" --region "$RUN_REGION" --format=json | python3 -c '
import json, sys, urllib.parse as up
env = {e["name"]: e.get("value", "") for e in json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0].get("env", [])}
print(up.urlsplit(env.get("DATABASE_URL", "")).hostname, up.urlsplit(env.get("MEILI_HOST", "")).hostname)')
read -r db_host meili_host <<< "$hosts"
if [[ "$db_host" != "$VM_INTERNAL_IP" || "$meili_host" != "$VM_INTERNAL_IP" ]]; then
  msg="backend still uses DATABASE_URL host=$db_host MEILI_HOST host=$meili_host; run 10-move-backend-to-internal-network.sh first"
  if is_dry_run; then log "preflight: [WOULD REFUSE] $msg (continuing only because DRY_RUN=1)"
  else die "$msg"; fi
else
  log "preflight: [OK] backend uses $VM_INTERNAL_IP for both datastores"
fi

# Previous source ranges, one file per rule (bash 3.2 on macOS has no associative arrays).
PREV_DIR=$(mktemp -d)
add_cleanup "$PREV_DIR"   # removed by the EXIT handler in lib/common.sh
prev() { cat "$PREV_DIR/$1"; }
for rule in $FIREWALL_RULES; do
  gc compute firewall-rules describe "$rule" --format='value(sourceRanges.list(separator=","))' > "$PREV_DIR/$rule"
  [[ -s "$PREV_DIR/$rule" ]] || die "could not read source ranges of $rule"
  log "before: $rule source ranges = $(prev "$rule")"
done

# Recovery: runs from the EXIT handler (lib/common.sh) on ANY exit while armed, with
# set +e. It tries EVERY rule even if one fails, reads each back, and reports.
restore_rules() {
  local rule want got ok="" bad="" manual=""
  for rule in $FIREWALL_RULES; do
    want=$(prev "$rule")
    log "ROLLBACK: $rule -> $want"
    run gc compute firewall-rules update "$rule" --source-ranges "$want" ||
      log "ROLLBACK: update of $rule FAILED; still checking its current state"
    got=$(gc compute firewall-rules describe "$rule" --format='value(sourceRanges.list(separator=","))' 2>/dev/null)
    if [[ "$got" == "$want" ]]; then ok="$ok $rule"
    else
      bad="$bad|$rule: source ranges now '${got:-unreadable}', wanted '$want'"
      manual="$manual|  gcloud compute firewall-rules update $rule --project $PROJECT --source-ranges $want"
    fi
  done
  if [[ -z "$bad" ]]; then
    alarm "FIREWALL RESTORED — the change was undone" \
      "Restored to their previous source ranges:$ok" \
      "That previous state had Postgres/Meilisearch open to the internet. Find the cause, then re-run this script."
  else
    local IFS='|'
    # shellcheck disable=SC2086
    alarm "FIREWALL RESTORE INCOMPLETE — check production search NOW" \
      "Restored:${ok:- none}" ${bad#|} \
      "Finish by hand:" ${manual#|} \
      "Then check: bash -c 'source $HERE/lib/common.sh; source $HERE/lib/verify-production.sh; verify_production && finish'"
  fi
}

# ---------------------------------------------------------------- change
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for rule in $FIREWALL_RULES; do
  if [[ "$(prev "$rule")" == "$RUN_SUBNET_RANGE" ]]; then
    log "change: $rule already limited to $RUN_SUBNET_RANGE — skipping"
  else
    # Armed before the first update. From here, any exit short of passing N4 restores.
    if [[ -z "$_RECOVERY" ]]; then arm_recovery restore_rules; fi
    run gc compute firewall-rules update "$rule" --source-ranges "$RUN_SUBNET_RANGE"
  fi
done

# ---------------------------------------------------------------- N4
if is_dry_run; then
  log "after: (dry run) N4 checks against CURRENT production as a baseline"
  verify_production || log "baseline checks failed — production is unhealthy BEFORE any change"
elif ! verify_production "$since"; then
  exit 1          # recovery is armed: the EXIT handler runs restore_rules
fi
# Production works on the narrowed rules. From here on, never reopen the ports.
disarm_recovery

# ---------------------------------------------------------------- probe
ext_ip=$(gc compute instances describe "$VM" --zone "$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
[[ -n "$ext_ip" ]] || die "VM has no external IP to probe"
open=0
for port in $PROBE_PORTS; do
  if python3 -c 'import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=float(sys.argv[3])).close()' \
       "$ext_ip" "$port" "$PROBE_TIMEOUT" 2>/dev/null; then
    log "probe: $ext_ip:$port is OPEN from this machine"
    open=1
  else
    log "probe: $ext_ip:$port refused or timed out after ${PROBE_TIMEOUT}s — closed from the internet"
  fi
done

if is_dry_run; then
  log "DRY RUN complete: nothing was changed (open ports above are expected before the change)"
  finish
fi
if [[ "$open" == 1 ]]; then
  log "FAIL: a database port is still reachable from the internet. Look for another rule admitting it:"
  log "      gcloud compute firewall-rules list --project $PROJECT"
  exit 1
fi
log "DONE: 5432 and 7700 only admit $RUN_SUBNET_RANGE; production checks pass"
finish
