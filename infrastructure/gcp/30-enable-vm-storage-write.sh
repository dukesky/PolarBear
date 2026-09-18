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
#   Recovery (recover_vm) is armed just before the stop. On ANY exit before
#   verified success it runs: a failed set-service-account, a failed start, a
#   crashed check, a set -e abort, Ctrl-C. It starts the VM if it is not RUNNING
#   (3 tries). If that fails, it prints the exact state and the snapshot-restore
#   pointer (runbook section C, snapshot $PRE_CHANGE_SNAPSHOT). If the VM is
#   up, it runs the full post-start checks and reports where things stand.
#   It does not undo a successful scope change, because that would need a
#   second outage. Every exit other than full success is non-zero.
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
: "${PRE_CHANGE_SNAPSHOT:=polarbear-services-pre-network-2026-09-18}"
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
a_ip=""; a_status=""
read -r a_ip a_status <<< "$addr" || true
if [[ "$a_ip" == "$VM_INTERNAL_IP" && "$a_status" == IN_USE ]]; then
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

# ---------------------------------------------------------------- helpers
vm_status() { gc compute instances describe "$VM" --zone "$ZONE" --format='value(status)' 2>/dev/null || echo UNKNOWN; }

# Every step is guarded, so this never aborts half way. It prints what it finds
# and returns non-zero if anything is wrong. Callers run it with `if`.
post_start_checks() {
  local failed=0 vm_json status got_scopes new_int_ip deadline ready
  if vm_json=$(gc compute instances describe "$VM" --zone "$ZONE" --format=json 2>/dev/null) &&
     status=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["status"])' "$vm_json") &&
     got_scopes=$(python3 -c 'import json,sys; print("\n".join(sorted(json.loads(sys.argv[1])["serviceAccounts"][0]["scopes"])))' "$vm_json") &&
     new_int_ip=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["networkInterfaces"][0]["networkIP"])' "$vm_json") &&
     NEW_EXT_IP=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["networkInterfaces"][0]["accessConfigs"][0].get("natIP",""))' "$vm_json"); then
    log "check: status=$status internal IP=$new_int_ip external IP=$NEW_EXT_IP (was $old_ext_ip; a change is expected)"
    if [[ "$status" == RUNNING ]]; then log "check: [OK] VM RUNNING"; else log "check: [FAIL] VM status is $status"; failed=1; fi
    if [[ "$new_int_ip" == "$VM_INTERNAL_IP" ]]; then log "check: [OK] internal IP unchanged ($VM_INTERNAL_IP)"
    else log "check: [FAIL] internal IP is $new_int_ip, expected $VM_INTERNAL_IP"; failed=1; fi
    if [[ "$got_scopes" == "$(sort <<< "$new_scopes")" ]]; then log "check: [OK] scopes are exactly as planned"
    else log "check: [FAIL] scopes differ from the plan; they are now:"; sed 's/^/    /' <<< "$got_scopes" >&2; failed=1; fi
  else
    log "check: [FAIL] could not read the VM's state from the API"; failed=1
  fi

  log "check: waiting up to ${CONTAINER_WAIT_SECONDS}s for both containers"
  deadline=$(( $(date +%s) + CONTAINER_WAIT_SECONDS )); ready=0
  while (( $(date +%s) < deadline )); do
    if vm_ssh "sudo docker inspect -f '{{.State.Running}}' $PG_CONTAINER $MEILI_CONTAINER | grep -qv true && exit 1;
               sudo docker exec $PG_CONTAINER pg_isready -q -U $PG_USER -d $PG_DB &&
               curl -fsS -o /dev/null http://127.0.0.1:7700/health" 2>/dev/null; then
      ready=1; break
    fi
    sleep 10
  done
  if [[ "$ready" == 1 ]]; then log "check: [OK] $PG_CONTAINER accepts connections and $MEILI_CONTAINER /health answers"
  else log "check: [FAIL] containers not ready after ${CONTAINER_WAIT_SECONDS}s"; failed=1; fi

  if vm_ssh "curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/scopes | grep -qxF '$RW'" 2>/dev/null; then
    log "check: [OK] the metadata server on the VM reports $RW"
  else
    log "check: [FAIL] the metadata server on the VM does not report $RW"; failed=1
  fi

  verify_production "$since" || failed=1
  return "$failed"
}

# Recovery: runs from the EXIT handler (lib/common.sh) with set +e on ANY exit
# between arming (just before the stop) and verified success. That covers a failed
# set-service-account, a failed or timed-out start, a crash, and Ctrl-C.
# Priority 1 is a RUNNING VM. Priority 2 is telling the human exactly where things stand.
recover_vm() {
  local status attempt scopes_now
  status=$(vm_status)
  log "RECOVERY: VM status is $status"
  attempt=1
  while [[ "$status" != RUNNING && "$attempt" -le 3 ]]; do
    log "RECOVERY: starting $VM (attempt $attempt of 3)"
    run gc compute instances start "$VM" --zone "$ZONE" || log "RECOVERY: start attempt $attempt failed"
    status=$(vm_status)
    if [[ "$status" != RUNNING ]]; then sleep 15; status=$(vm_status); fi
    attempt=$((attempt + 1))
  done
  scopes_now=$(gc compute instances describe "$VM" --zone "$ZONE" --format='value(serviceAccounts[0].scopes)' 2>/dev/null || echo unreadable)
  if [[ "$status" != RUNNING ]]; then
    alarm "VM IS NOT RUNNING — PRODUCTION SEARCH IS DOWN" \
      "VM $VM status: $status   (3 start attempts failed)" \
      "Scopes now: $scopes_now" \
      "1. Try again:    gcloud compute instances start $VM --zone $ZONE --project $PROJECT" \
      "2. Look:         gcloud compute instances describe $VM --zone $ZONE --project $PROJECT --format='yaml(status,statusMessage)'" \
      "                 gcloud compute instances get-serial-port-output $VM --zone $ZONE --project $PROJECT | tail -50" \
      "3. If it will not boot: restore the VM from a snapshot, docs/operations/backup-restore.md section C." \
      "   Pre-change snapshot: $PRE_CHANGE_SNAPSHOT (also: the newest polarbear-daily-snapshots snapshot, if any)."
    return
  fi
  log "RECOVERY: VM is RUNNING; running the post-start checks so you know where things stand"
  if post_start_checks; then
    alarm "N6 DID NOT FINISH CLEANLY, BUT PRODUCTION IS UP" \
      "VM RUNNING, containers healthy, production checks pass." \
      "Scopes now: $scopes_now" \
      "If devstorage.read_write is not in that list, the scope change did not happen; re-running this script is safe (it is another short outage)."
  else
    alarm "N6 FAILED — VM IS RUNNING BUT CHECKS FAIL (see [FAIL] lines above)" \
      "Scopes now: $scopes_now" \
      "Restore service first: docs/operations/backup-restore.md ('Checking Production After a Restore', then section C if needed)." \
      "Pre-change snapshot: $PRE_CHANGE_SNAPSHOT"
  fi
}

# ---------------------------------------------------------------- change
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NEW_EXT_IP=""
# Armed BEFORE the stop: from here, any exit short of verified success runs recover_vm.
arm_recovery recover_vm
run gc compute instances stop "$VM" --zone "$ZONE"
run gc compute instances set-service-account "$VM" --zone "$ZONE" \
  --service-account "$sa" --scopes "$new_csv"
run gc compute instances start "$VM" --zone "$ZONE"

if is_dry_run; then
  log "(dry run) would then check: VM RUNNING, scopes exactly as planned, internal IP still $VM_INTERNAL_IP,"
  log "          both containers ready (up to ${CONTAINER_WAIT_SECONDS}s), metadata server reports $RW, and the N4 checks."
  log "(dry run) on any failure from the stop onwards, recover_vm would start the VM (3 tries) and report."
  log "DRY RUN complete: nothing was changed"
  exit 0
fi

# ---------------------------------------------------------------- verify
log "after: VM started; verifying"
if post_start_checks; then
  disarm_recovery
  log "DONE: $VM has $RW, internal IP $VM_INTERNAL_IP unchanged, new external IP $NEW_EXT_IP, production checks pass"
  exit 0
fi
disarm_recovery   # the VM is running; recovery would only repeat these same checks
alarm "N6 FAILED — VM IS RUNNING BUT CHECKS FAIL (see [FAIL] lines above)" \
  "Restore service first: docs/operations/backup-restore.md ('Checking Production After a Restore', then section C if needed)." \
  "Pre-change snapshot: $PRE_CHANGE_SNAPSHOT"
exit 1
