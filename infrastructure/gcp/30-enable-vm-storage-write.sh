#!/usr/bin/env bash
# 30 — Let the VM write to Cloud Storage  (brief step N6, the ONE planned downtime)
#
# CHANGES
#   The VM's OAuth scopes: devstorage.read_only is swapped for
#   devstorage.read_write, and every other existing scope is kept. GCP only allows
#   this on a stopped VM, so the script STOPS the VM, sets the scopes and STARTS
#   it. Search is down for about 1–2 minutes. The containers restart on their own
#   (restart: always). The ephemeral EXTERNAL IP changes, which is expected. After
#   steps 10 and 20 nothing depends on it. The INTERNAL IP is reserved and does
#   not change.
#
# VERIFIES
#   Before: the backend already uses the internal IP, and that IP is reserved.
#   Otherwise the restart would break production, so the script refuses.
#   It prints the exact scope list it will apply and waits for a typed `yes`.
#   After: VM RUNNING, scopes as printed, internal IP unchanged, both containers
#   running and answering, then the N4 production checks.
#
# ROLLS BACK
#   Once the VM is stopped, the script ALWAYS tries to start it again, even if
#   setting the scopes failed. It does not undo a successful scope change,
#   because that would need a second outage. If the checks fail afterwards,
#   it exits non-zero and prints what failed. The pre-change snapshot
#   (polarbear-services-pre-network-2026-09-18) is the last resort. See
#   docs/operations/backup-restore.md.
#
# SAFE TO RE-RUN: if the scope is already read_write, it skips the restart and only verifies.
#
# Usage:  DRY_RUN=1 ./30-enable-vm-storage-write.sh
#         ./30-enable-vm-storage-write.sh          # needs an interactive terminal for the 'yes'
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/verify-production.sh
source "$HERE/lib/verify-production.sh"

: "${CONTAINER_WAIT_SECONDS:=300}"
RO=https://www.googleapis.com/auth/devstorage.read_only
RW=https://www.googleapis.com/auth/devstorage.read_write

require gcloud python3 curl
banner "30: give $VM the Cloud Storage read_write scope (stop/start)"

# ---------------------------------------------------------------- preflight
refuse() {
  if is_dry_run; then log "preflight: [WOULD REFUSE] $* (continuing only because DRY_RUN=1)"
  else die "$*"; fi
}
addr=$(gc compute addresses describe "$VM_INTERNAL_ADDRESS_NAME" --region "$REGION" \
         --format='value(address,status)' 2>/dev/null || true)
if [[ "$addr" == "$VM_INTERNAL_IP"*IN_USE ]]; then
  log "preflight: [OK] internal IP $VM_INTERNAL_IP is reserved ($VM_INTERNAL_ADDRESS_NAME, IN_USE)"
else
  refuse "internal IP is not reserved as $VM_INTERNAL_ADDRESS_NAME (got '$addr'); a restart could change it"
fi
hosts=$(gc run services describe "$RUN_SERVICE" --region "$RUN_REGION" --format=json | python3 -c '
import json, sys, urllib.parse as up
env = {e["name"]: e.get("value", "") for e in json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0].get("env", [])}
print(up.urlsplit(env.get("DATABASE_URL", "")).hostname, up.urlsplit(env.get("MEILI_HOST", "")).hostname)')
read -r db_host meili_host <<< "$hosts"
if [[ "$db_host" == "$VM_INTERNAL_IP" && "$meili_host" == "$VM_INTERNAL_IP" ]]; then
  log "preflight: [OK] backend uses $VM_INTERNAL_IP, so the external IP changing is harmless"
else
  refuse "backend still uses DATABASE_URL host=$db_host MEILI_HOST host=$meili_host — the external IP will change on restart; run 10 first"
fi

vm_json=$(gc compute instances describe "$VM" --zone "$ZONE" --format=json)
sa=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["serviceAccounts"][0]["email"])' "$vm_json")
cur_scopes=$(python3 -c 'import json,sys; print("\n".join(json.loads(sys.argv[1])["serviceAccounts"][0]["scopes"]))' "$vm_json")
old_ext_ip=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["networkInterfaces"][0]["accessConfigs"][0].get("natIP",""))' "$vm_json")
old_int_ip=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["networkInterfaces"][0]["networkIP"])' "$vm_json")
log "before: service account $sa"
log "before: internal IP $old_int_ip, external IP $old_ext_ip"
log "before: current scopes:"
sed 's/^/    /' <<< "$cur_scopes" >&2

if ! grep -qxF "$RO" <<< "$cur_scopes" && grep -qxF "$RW" <<< "$cur_scopes"; then
  log "change: VM already has $RW — no restart needed"
  is_dry_run || verify_production "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  exit 0
fi
grep -qxF "$RO" <<< "$cur_scopes" || die "expected $RO among the current scopes; refusing to guess"

new_scopes=$(sed "s#^$RO\$#$RW#" <<< "$cur_scopes")
new_csv=$(paste -sd, - <<< "$new_scopes")
log "PLAN: the VM's scopes will be set to EXACTLY:"
sed 's/^/    /' <<< "$new_scopes" >&2
log "PLAN: stop $VM -> set scopes -> start $VM  (search is down for ~1-2 minutes)"

# ---------------------------------------------------------------- confirm
if is_dry_run; then
  log "(dry run) would now ask: Type 'yes' to stop $VM"
else
  [[ -r /dev/tty ]] || die "needs an interactive terminal for the confirmation"
  printf "Type 'yes' to stop %s now: " "$VM" > /dev/tty
  read -r answer < /dev/tty
  [[ "$answer" == yes ]] || die "not confirmed ('$answer'); nothing was changed"
fi

# ---------------------------------------------------------------- change
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STOPPED=0
STARTED=0
ensure_started() {
  if [[ "$STOPPED" == 1 && "$STARTED" == 0 ]]; then
    log "SAFETY: the VM was stopped and not yet started — starting it now"
    gc compute instances start "$VM" --zone "$ZONE" && STARTED=1
  fi
}
trap ensure_started EXIT

run gc compute instances stop "$VM" --zone "$ZONE"
is_dry_run || STOPPED=1
run gc compute instances set-service-account "$VM" --zone "$ZONE" \
  --service-account "$sa" --scopes "$new_csv"
run gc compute instances start "$VM" --zone "$ZONE"
is_dry_run || STARTED=1

if is_dry_run; then
  log "(dry run) would then wait up to ${CONTAINER_WAIT_SECONDS}s for $PG_CONTAINER and $MEILI_CONTAINER,"
  log "          check the internal IP is still $VM_INTERNAL_IP, and run the N4 checks."
  log "DRY RUN complete: nothing was changed"
  exit 0
fi

# ---------------------------------------------------------------- verify VM
failed=0
vm_json=$(gc compute instances describe "$VM" --zone "$ZONE" --format=json)
status=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$vm_json")
got_scopes=$(python3 -c 'import json,sys; print("\n".join(sorted(json.loads(sys.argv[1])["serviceAccounts"][0]["scopes"])))' "$vm_json")
new_int_ip=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["networkInterfaces"][0]["networkIP"])' "$vm_json")
new_ext_ip=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["networkInterfaces"][0]["accessConfigs"][0].get("natIP",""))' "$vm_json")
log "after: status=$status internal IP=$new_int_ip external IP=$new_ext_ip (was $old_ext_ip; a change is expected)"
[[ "$status" == RUNNING ]] || { log "FAIL: VM status is $status"; failed=1; }
[[ "$new_int_ip" == "$VM_INTERNAL_IP" ]] || { log "FAIL: internal IP changed to $new_int_ip"; failed=1; }
if [[ "$got_scopes" == "$(sort <<< "$new_scopes")" ]]; then log "after: [OK] scopes are exactly as planned"
else log "FAIL: scopes differ from the plan:"; sed 's/^/    /' <<< "$got_scopes" >&2; failed=1; fi

log "after: waiting up to ${CONTAINER_WAIT_SECONDS}s for both containers"
deadline=$(( $(date +%s) + CONTAINER_WAIT_SECONDS ))
ready=0
while (( $(date +%s) < deadline )); do
  if vm_ssh "sudo docker inspect -f '{{.State.Running}}' $PG_CONTAINER $MEILI_CONTAINER | grep -qv true && exit 1;
             sudo docker exec $PG_CONTAINER pg_isready -q -U $PG_USER -d $PG_DB &&
             curl -fsS -o /dev/null http://127.0.0.1:7700/health" 2>/dev/null; then
    ready=1; break
  fi
  sleep 10
done
if [[ "$ready" == 1 ]]; then log "after: [OK] $PG_CONTAINER accepts connections and $MEILI_CONTAINER /health answers"
else log "FAIL: containers not ready after ${CONTAINER_WAIT_SECONDS}s"; failed=1; fi

if vm_ssh "curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/scopes | grep -qxF '$RW'"; then
  log "after: [OK] the metadata server on the VM reports $RW"
else
  log "FAIL: metadata server on the VM does not report $RW"; failed=1
fi

# ---------------------------------------------------------------- N4
verify_production "$since" || failed=1

if [[ "$failed" == 1 ]]; then
  log "N6 FAILED — see above. Restore service first; runbook: docs/operations/backup-restore.md"
  exit 1
fi
log "DONE: $VM has $RW, internal IP $VM_INTERNAL_IP unchanged, new external IP $new_ext_ip, production checks pass"
