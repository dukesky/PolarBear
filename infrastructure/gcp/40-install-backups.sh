#!/usr/bin/env bash
# 40 — Install production backups  (brief R1, R2, R6, and R3–R5 on the VM)
#
# CHANGES
#   R1  Snapshot schedule `polarbear-daily-snapshots` in us-west1: daily at
#       10:00 UTC, kept 7 days, stored in us-west1 (regional), attached to disk
#       polarbear-services.
#   R2  Bucket gs://polarbear-backups-479000 in us-west1: uniform bucket-level
#       access, public access prevention enforced, objects deleted after 30 days.
#   R6  gs://polarbear-indexes-479000: object versioning ON, noncurrent versions
#       deleted once 3 newer noncurrent ones exist or after 30 days noncurrent.
#       This REPLACES that bucket's lifecycle config. The script refuses if the
#       bucket already has a different, non-empty lifecycle config.
#   R3–R5  Copies vm/backup.sh to /opt/polarbear/backup.sh (root, 0700) and puts
#       ONE line in root's crontab (09:17 UTC daily). Runs it once and lists the
#       two objects it uploaded.
#
# VERIFIES
#   Reads each resource back after changing it and checks the fields the
#   brief asks for. Checks the VM can write to Cloud Storage before it
#   installs anything (run 30-enable-vm-storage-write.sh first). After the
#   first run, checks both objects exist in the bucket.
#
# ROLLS BACK  (manual; nothing here touches live traffic)
#   R1  gcloud compute disks remove-resource-policies polarbear-services --zone us-west1-b --resource-policies polarbear-daily-snapshots
#   R2  the bucket is new; delete it only if it holds nothing you need
#   R6  gcloud storage buckets update gs://polarbear-indexes-479000 --no-versioning --clear-lifecycle
#   cron  sudo crontab -l | grep -vF /opt/polarbear/backup.sh | sudo crontab -
#
# SAFE TO RE-RUN: existing resources are checked, not recreated. The cron line
# is replaced, never duplicated. Each run does make one more backup.
#
# Usage:  DRY_RUN=1 ./40-install-backups.sh
#         ./40-install-backups.sh
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

: "${SNAPSHOT_POLICY:=polarbear-daily-snapshots}"
: "${SNAPSHOT_START_UTC:=10:00}"            # snapshot schedules only take whole hours
: "${SNAPSHOT_RETENTION_DAYS:=7}"
: "${BACKUP_BUCKET:=gs://polarbear-backups-479000}"
: "${BACKUP_RETENTION_DAYS:=30}"
: "${INDEX_BUCKET:=gs://polarbear-indexes-479000}"
: "${INDEX_NONCURRENT_KEEP:=3}"
: "${INDEX_NONCURRENT_DAYS:=30}"
: "${REMOTE_SCRIPT:=/opt/polarbear/backup.sh}"
: "${CRON_SCHEDULE:=17 9 * * *}"            # 09:17 UTC = 02:17 PDT / 01:17 PST, off the hour
: "${RUN_BACKUP_NOW:=1}"

CRON_LINE="$CRON_SCHEDULE $REMOTE_SCRIPT >/dev/null 2>&1  # polarbear nightly backup; output is in /var/log/polarbear-backup.log"
RW=https://www.googleapis.com/auth/devstorage.read_write

require gcloud python3
banner "40: install backups"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
failed=0
check() {  # check DESCRIPTION COMMAND... — records a pass/fail without stopping
  local what=$1; shift
  if "$@"; then log "  [OK]   $what"; else log "  [FAIL] $what"; failed=1; fi
}

# ================================================================ R1
log "R1: snapshot schedule $SNAPSHOT_POLICY"
if gc compute resource-policies describe "$SNAPSHOT_POLICY" --region "$REGION" --format=json > "$TMP/policy.json" 2>/dev/null; then
  log "R1: policy exists; checking it"
else
  run gc compute resource-policies create snapshot-schedule "$SNAPSHOT_POLICY" \
    --region "$REGION" \
    --description "Daily snapshot of the PolarBear VM disk, kept ${SNAPSHOT_RETENTION_DAYS} days" \
    --daily-schedule --start-time "$SNAPSHOT_START_UTC" \
    --max-retention-days "$SNAPSHOT_RETENTION_DAYS" \
    --on-source-disk-delete keep-auto-snapshots \
    --storage-location "$REGION"
  if ! is_dry_run; then gc compute resource-policies describe "$SNAPSHOT_POLICY" --region "$REGION" --format=json > "$TMP/policy.json"; fi
fi
attached=$(gc compute disks describe "$DISK" --zone "$ZONE" --format='value(resourcePolicies.list())')
if [[ "$attached" == *"/$SNAPSHOT_POLICY"* ]]; then
  log "R1: already attached to disk $DISK"
else
  run gc compute disks add-resource-policies "$DISK" --zone "$ZONE" --resource-policies "$SNAPSHOT_POLICY"
fi
if ! is_dry_run; then
  check "policy is daily, ${SNAPSHOT_RETENTION_DAYS}-day retention, stored in $REGION" python3 - "$TMP/policy.json" "$SNAPSHOT_RETENTION_DAYS" "$REGION" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))["snapshotSchedulePolicy"]
ok = ("dailySchedule" in p["schedule"]
      and int(p["retentionPolicy"]["maxRetentionDays"]) == int(sys.argv[2])
      and p.get("snapshotProperties", {}).get("storageLocations") == [sys.argv[3]])
print("    schedule=%s retention=%s storage=%s" % (p["schedule"], p["retentionPolicy"]["maxRetentionDays"],
      p.get("snapshotProperties", {}).get("storageLocations")), file=sys.stderr)
sys.exit(0 if ok else 1)
PY
  attached=$(gc compute disks describe "$DISK" --zone "$ZONE" --format='value(resourcePolicies.list())')
  check "policy attached to disk $DISK" [ -n "$attached" -a -z "${attached##*/$SNAPSHOT_POLICY*}" ]
fi

# ================================================================ R2
log "R2: backup bucket $BACKUP_BUCKET"
cat > "$TMP/backup-lifecycle.json" <<EOF
{"rule": [{"action": {"type": "Delete"}, "condition": {"age": $BACKUP_RETENTION_DAYS}}]}
EOF
if gc storage buckets describe "$BACKUP_BUCKET" --format=json > "$TMP/bb.json" 2>/dev/null; then
  log "R2: bucket exists; re-asserting its settings"
else
  run gc storage buckets create "$BACKUP_BUCKET" --location "$REGION" \
    --default-storage-class STANDARD --uniform-bucket-level-access --public-access-prevention
fi
if is_dry_run; then log "R2: lifecycle would be: $(cat "$TMP/backup-lifecycle.json")"; fi
run gc storage buckets update "$BACKUP_BUCKET" --uniform-bucket-level-access \
  --public-access-prevention --lifecycle-file "$TMP/backup-lifecycle.json"
if ! is_dry_run; then
  gc storage buckets describe "$BACKUP_BUCKET" --format=json > "$TMP/bb.json"
  check "location $REGION, UBLA on, PAP enforced, delete after ${BACKUP_RETENTION_DAYS}d" python3 - "$TMP/bb.json" "$REGION" "$BACKUP_RETENTION_DAYS" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
rules = b.get("lifecycle_config", {}).get("rule", [])
print("    location=%s ubla=%s pap=%s lifecycle=%s" % (b.get("location"), b.get("uniform_bucket_level_access"),
      b.get("public_access_prevention"), json.dumps(rules)), file=sys.stderr)
ok = (b.get("location", "").lower() == sys.argv[2].lower()
      and b.get("uniform_bucket_level_access") is True
      and b.get("public_access_prevention") == "enforced"
      and any(r["action"]["type"] == "Delete" and r["condition"].get("age") == int(sys.argv[3]) for r in rules))
sys.exit(0 if ok else 1)
PY
fi

# ================================================================ R6
log "R6: versioning + noncurrent-version lifecycle on $INDEX_BUCKET"
# numNewerVersions counts the live version too, so keeping N noncurrent
# versions means deleting a noncurrent version once it has N+1 newer ones.
cat > "$TMP/index-lifecycle.json" <<EOF
{"rule": [
  {"action": {"type": "Delete"}, "condition": {"isLive": false, "numNewerVersions": $((INDEX_NONCURRENT_KEEP + 1))}},
  {"action": {"type": "Delete"}, "condition": {"isLive": false, "daysSinceNoncurrentTime": $INDEX_NONCURRENT_DAYS}}
]}
EOF
gc storage buckets describe "$INDEX_BUCKET" --format=json > "$TMP/ib.json"
python3 - "$TMP/ib.json" "$TMP/index-lifecycle.json" <<'PY' || die "$INDEX_BUCKET already has a different lifecycle config; merge it by hand into $TMP/index-lifecycle.json's rules first"
import json, sys
cur = json.load(open(sys.argv[1])).get("lifecycle_config", {}).get("rule", [])
want = json.load(open(sys.argv[2]))["rule"]
norm = lambda rs: sorted(json.dumps(r, sort_keys=True) for r in rs)
sys.exit(0 if not cur or norm(cur) == norm(want) else 1)
PY
if is_dry_run; then log "R6: lifecycle would be: $(tr -d '\n' < "$TMP/index-lifecycle.json")"; fi
run gc storage buckets update "$INDEX_BUCKET" --versioning --lifecycle-file "$TMP/index-lifecycle.json"
if ! is_dry_run; then
  gc storage buckets describe "$INDEX_BUCKET" --format=json > "$TMP/ib.json"
  check "versioning on; noncurrent kept <= $INDEX_NONCURRENT_KEEP and <= ${INDEX_NONCURRENT_DAYS}d" python3 - "$TMP/ib.json" "$TMP/index-lifecycle.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1])); want = json.load(open(sys.argv[2]))["rule"]
cur = b.get("lifecycle_config", {}).get("rule", [])
print("    versioning=%s lifecycle=%s" % (b.get("versioning_enabled"), json.dumps(cur)), file=sys.stderr)
norm = lambda rs: sorted(json.dumps(r, sort_keys=True) for r in rs)
sys.exit(0 if b.get("versioning_enabled") is True and norm(cur) == norm(want) else 1)
PY
fi

# ================================================================ R3–R5 on the VM
log "R3-R5: backup script and cron on $VM"
scopes=$(gc compute instances describe "$VM" --zone "$ZONE" --format='value(serviceAccounts[0].scopes)')
if [[ "$scopes" != *"$RW"* ]]; then
  if is_dry_run; then log "R3-R5: [WOULD REFUSE] VM lacks $RW; run 30-enable-vm-storage-write.sh first (continuing only because DRY_RUN=1)"
  else die "VM lacks $RW; run 30-enable-vm-storage-write.sh first"; fi
fi
bash -n "$HERE/vm/backup.sh" || die "vm/backup.sh has a syntax error"

run gcloud compute scp "$HERE/vm/backup.sh" "$VM:/tmp/polarbear-backup.sh" \
  --zone "$ZONE" --project "$PROJECT" --quiet
run vm_ssh "sudo install -o root -g root -m 0700 /tmp/polarbear-backup.sh $REMOTE_SCRIPT && rm -f /tmp/polarbear-backup.sh \
  && sudo touch /var/log/polarbear-backup.log && sudo chmod 0640 /var/log/polarbear-backup.log"
# Replace any previous polarbear backup line, then add exactly one.
run vm_ssh "{ sudo crontab -l 2>/dev/null | grep -vF '$REMOTE_SCRIPT' || true; echo '$CRON_LINE'; } | sudo crontab -"

if ! is_dry_run; then
  check "installed script matches vm/backup.sh" \
    [ "$(vm_ssh "sudo sha256sum $REMOTE_SCRIPT" | awk '{print $1}')" = "$(shasum -a 256 "$HERE/vm/backup.sh" | awk '{print $1}')" ]
  n=$(vm_ssh "sudo crontab -l | grep -cF '$REMOTE_SCRIPT'" || true)
  check "exactly one cron line for $REMOTE_SCRIPT (found $n)" [ "$n" = 1 ]
  vm_ssh "sudo crontab -l | grep -F '$REMOTE_SCRIPT'" | sed 's/^/    /' >&2
fi

# ================================================================ first run
if [[ "$RUN_BACKUP_NOW" != 1 ]]; then
  log "first run: skipped (RUN_BACKUP_NOW=$RUN_BACKUP_NOW)"
elif is_dry_run; then
  run vm_ssh "sudo $REMOTE_SCRIPT"
  log "(dry run) would then list the two uploaded objects with: gcloud storage ls -l <each gs:// URL from the 'uploaded' lines>"
else
  log "first run: sudo $REMOTE_SCRIPT"
  if out=$(vm_ssh "sudo $REMOTE_SCRIPT" 2>&1); then rc=0; else rc=$?; fi
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  if [[ "$rc" != 0 ]]; then log "first run FAILED (exit $rc)"; failed=1
  else
    objs=$(printf '%s\n' "$out" | sed -n -E 's/.*uploaded (gs:[^ ]+) .*/\1/p')
    check "two objects uploaded" [ "$(printf '%s\n' "$objs" | grep -c '^gs://')" = 2 ]
    for o in $objs; do
      check "present in bucket: $o" gc storage ls -l "$o"
    done
  fi
fi

if is_dry_run; then log "DRY RUN complete: nothing was changed"; exit 0; fi
if [[ "$failed" != 0 ]]; then log "SOME CHECKS FAILED — see [FAIL] lines above"; exit 1; fi
log "DONE: R1, R2, R6 in place; backup installed, cron set, first run uploaded both objects"
