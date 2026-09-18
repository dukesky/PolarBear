#!/usr/bin/env bash
# 35 — Rotate the Postgres password and Meilisearch master key into Secret Manager
#
# WHY: both values were exposed (2026-09-18), and the VM's startup-script held them in
# plaintext instance metadata, readable by any process on the VM without auth.
# Order: 10 and 20 have run -> 35 -> 30 -> 40. Script 30's reboot then proves this survives a boot.
#
# CHANGES (in order)
#   S0  on-demand snapshot polarbear-services-pre-rotation-<UTC date> (waits for READY)
#   S2  Secret Manager: polarbear-postgres-password, polarbear-meili-master-key,
#       polarbear-database-url (full asyncpg URL). Created if missing (user-managed replica in
#       us-central1), then a NEW VERSION each. The Cloud Run runtime service account gets
#       roles/secretmanager.secretAccessor on EACH secret (resource level, not project level).
#   S3  VM metadata `startup-script` -> vm/startup-script.sh (secret-free; never writes compose.yml)
#   S4  on the VM (vm/datastore-secrets.sh apply): backup compose.yml, replace ONLY the two values,
#       ALTER USER, docker compose up -d, wait healthy.            <- planned downtime starts here
#   S5  Cloud Run, ONE update: plaintext DATABASE_URL and MEILI_MASTER_KEY removed and re-added
#       as secret references PINNED to the S2 version numbers.   <- downtime ends when it serves
#   S7  on success: shred the VM-side backup; delete the local copy of the old metadata; point the
#       version alias `in-use` of all three secrets at the new versions (the runbook rebuild reads it).
#
# VERIFIES
#   S0 preflight: the backend is on 10.138.0.2 and 5432/7700 admit only 10.128.0.0/20 (refuses
#   otherwise); VM-side preflight (both keys present once, no leftover backup, Postgres
#   log_statement=none); compose.template.yml still renders to the live compose.yml.
#   After S3: the metadata reads back byte-identical to vm/startup-script.sh.
#   After S5: per-variable SHA-256. Only DATABASE_URL and MEILI_MASTER_KEY may differ, and both
#   must be secret refs to the exact S2 versions.
#   S6: the shared production checks; then the OLD values are proven dead (Meilisearch rejects
#   the old key, Postgres rejects the old password over TCP/scram, each with the new value as a
#   positive control); then the new startup-script metadata is shown to contain neither the old
#   nor the new values (counts only).
#
# ROLLS BACK
#   Recovery is armed right before S3. ANY exit before the S6 production checks pass runs it,
#   best effort, and prints what is and is not restored: VM (compose.yml from the backup,
#   ALTER USER back, compose up), Cloud Run traffic back to the revision serving at start, and
#   the old startup-script metadata. The S2 Secret Manager versions are LEFT BEHIND (unused);
#   the banner says so. After a rollback the LEAKED values are back in service, so rotation is
#   still needed. Once the production checks pass, recovery is disarmed: if a later "old
#   secret is dead" proof fails, rolling back would only re-enable the leaked secrets, so the
#   script alarms and exits non-zero instead.
#
# SECRET HANDLING: new values are generated locally (32 random bytes, hex) and held only in
# shell variables. They go to Secret Manager and to the VM on STDIN. They are never in argv, never
# printed, never logged. `run` never receives a secret. OUTSIDE THIS SCRIPT'S CONTROL: gcloud's
# own error messages.
#
# SAFE TO RE-RUN: each run is a fresh rotation (new versions, re-pinned). The VM step refuses
# if a previous run left compose.yml.pre-rotation behind.
#
# Usage:  DRY_RUN=1 ./35-rotate-datastore-secrets.sh
#         ./35-rotate-datastore-secrets.sh
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/verify-production.sh
source "$HERE/lib/verify-production.sh"
# shellcheck source=lib/cloudrun.sh
source "$HERE/lib/cloudrun.sh"

: "${SECRET_PG:=polarbear-postgres-password}"
: "${SECRET_MEILI:=polarbear-meili-master-key}"
: "${SECRET_DBURL:=polarbear-database-url}"
: "${SECRET_LOCATION:=$RUN_REGION}"
: "${HELPER:=/opt/polarbear/datastore-secrets.sh}"
: "${FIREWALL_RULES:=allow-postgres allow-meilisearch}"
: "${IAM_WAIT_SECONDS:=60}"

require gcloud python3 curl openssl
banner "35: rotate datastore secrets into Secret Manager"

TMP=$(mktemp -d)                 # service JSON (contains values), hashes
add_cleanup "$TMP"
PRIV=$(mktemp -d)                # the old startup-script (contains the LEAKED values), for rollback only
add_cleanup "$PRIV"
OLD_META="$PRIV/old-startup-script"

# ================================================================ S0 preflight
STEP_NOTE="S0 preflight"
describe_service_json "$TMP/start.json"
# (Command substitution, not <(...): bash 3.2 cannot parse a heredoc inside a process substitution.)
hosts_out=$(python3 - "$TMP/start.json" <<'PY'
import json, sys, urllib.parse as up
env = {e["name"]: e for e in json.load(open(sys.argv[1]))["spec"]["template"]["spec"]["containers"][0].get("env", [])}
db = env.get("DATABASE_URL", {})
kind = "literal" if "value" in db else "secret"
dbh = up.urlsplit(db["value"]).hostname if kind == "literal" else "-"
print(kind, dbh, up.urlsplit(env.get("MEILI_HOST", {}).get("value", "")).hostname)
PY
)
read -r db_kind db_host meili_host <<< "$hosts_out"
refuse() { if is_dry_run; then log "preflight: [WOULD REFUSE] $* (continuing only because DRY_RUN=1)"; else die "$*"; fi; }
if [[ "$meili_host" == "$VM_INTERNAL_IP" && ( "$db_kind" == secret || "$db_host" == "$VM_INTERNAL_IP" ) ]]; then
  log "preflight: [OK] backend uses $VM_INTERNAL_IP (DATABASE_URL is $db_kind)"
else refuse "backend is not on $VM_INTERNAL_IP (DATABASE_URL host=$db_host, MEILI_HOST host=$meili_host); run 10 first"; fi
for rule in $FIREWALL_RULES; do
  r=$(gc compute firewall-rules describe "$rule" --format='value(sourceRanges.list(separator=","))')
  if [[ "$r" == "$RUN_SUBNET_RANGE" ]]; then log "preflight: [OK] $rule admits only $r"
  else refuse "$rule admits '$r', not only $RUN_SUBNET_RANGE; run 20 first"; fi
done
gc services list --enabled --filter='config.name:secretmanager.googleapis.com' --format='value(config.name)' | grep -q secretmanager ||
  refuse "the Secret Manager API is not enabled (gcloud services enable secretmanager.googleapis.com)"
log "preflight: VM-side checks (read-only; the helper is streamed over stdin, nothing is written)"
if vm_ssh "sudo bash -s -- preflight" < "$HERE/vm/datastore-secrets.sh" 2>&1 | sed 's/^/    /' >&2; [[ "${PIPESTATUS[0]}" == 0 ]]; then
  log "preflight: [OK] VM-side checks"
else refuse "VM-side preflight failed (see above)"; fi

# The URL parts other than the password come from today's DATABASE_URL, or the defaults on a re-run.
url_out=$(python3 - "$TMP/start.json" "$PG_USER" "$PG_DB" <<'PY'
import json, sys, urllib.parse as up
env = {e["name"]: e for e in json.load(open(sys.argv[1]))["spec"]["template"]["spec"]["containers"][0].get("env", [])}
db = env.get("DATABASE_URL", {})
if "value" in db:
    p = up.urlsplit(db["value"])
    print(p.scheme, p.username, p.port or 5432, p.path.lstrip("/"))
else:
    print("postgresql+asyncpg", sys.argv[2], 5432, sys.argv[3])
PY
)
read -r U_SCHEME U_USER U_PORT U_DB <<< "$url_out"
log "preflight: new DATABASE_URL will be $U_SCHEME://$U_USER:<new password>@$VM_INTERNAL_IP:$U_PORT/$U_DB"
[[ "$U_USER" == "$PG_USER" ]] || die "DATABASE_URL user is $U_USER but PG_USER is $PG_USER"

START_REV=$(serving_revision); [[ -n "$START_REV" ]] || die "cannot read the serving revision"
log "preflight: serving revision $START_REV (rollback target)"
env_hashes "$TMP/start.json" > "$TMP/before.hashes"; show_hashes "$TMP/before.hashes" "before"
RUN_SA=$(runtime_service_account); log "preflight: Cloud Run runtime service account $RUN_SA"

# ================================================================ S0 snapshot
SNAP="polarbear-services-pre-rotation-$(date -u +%Y%m%d)"
if gc compute snapshots describe "$SNAP" --format='value(status)' >/dev/null 2>&1; then
  SNAP="$SNAP-$(date -u +%H%M%S)"
fi
run gc compute snapshots create "$SNAP" --source-disk "$DISK" --source-disk-zone "$ZONE" --storage-location "$REGION"
if ! is_dry_run; then
  [[ "$(gc compute snapshots describe "$SNAP" --format='value(status)')" == READY ]] || die "snapshot $SNAP is not READY"
  log "S0: [OK] snapshot $SNAP READY"
fi

# ================================================================ S1 generate
if is_dry_run; then
  NEW_PG="<generated>"; NEW_MEILI="<generated>"; NEW_DBURL="<generated>"
  log "S1: (dry run) would generate two values with 'openssl rand -hex 32' (held in variables, never printed)"
else
  NEW_PG=$(openssl rand -hex 32); NEW_MEILI=$(openssl rand -hex 32)
  [[ "$NEW_PG" =~ ^[0-9a-f]{64}$ && "$NEW_MEILI" =~ ^[0-9a-f]{64}$ && "$NEW_PG" != "$NEW_MEILI" ]] || die "secret generation failed"
  NEW_DBURL="$U_SCHEME://$U_USER:$NEW_PG@$VM_INTERNAL_IP:$U_PORT/$U_DB"
  log "S1: generated two new 64-hex values (not shown)"
fi

# ================================================================ S2 Secret Manager
ensure_secret() {
  if gc secrets describe "$1" --format='value(name)' >/dev/null 2>&1; then log "S2: secret $1 exists"
  else run gc secrets create "$1" --replication-policy user-managed --locations "$SECRET_LOCATION" --labels app=polarbear; fi
}
add_version() {  # add_version SECRET VALUE: the value goes on stdin. Prints the new version NUMBER.
  if is_dry_run; then
    printf 'DRY-RUN would run: gcloud secrets versions add %s --data-file=- --project %s   (value on stdin, not shown)\n' "$1" "$PROJECT" >&2
    echo "<N>"; return 0
  fi
  local name
  name=$(printf '%s' "$2" | gc secrets versions add "$1" --data-file=- --format='value(name)')
  echo "${name##*/}"
}
grant() {
  run gc secrets add-iam-policy-binding "$1" --member "serviceAccount:$RUN_SA" \
    --role roles/secretmanager.secretAccessor --format=none
}
for s in "$SECRET_PG" "$SECRET_MEILI" "$SECRET_DBURL"; do ensure_secret "$s"; done
V_PG=$(add_version "$SECRET_PG" "$NEW_PG")
V_MEILI=$(add_version "$SECRET_MEILI" "$NEW_MEILI")
V_DBURL=$(add_version "$SECRET_DBURL" "$NEW_DBURL")
if ! is_dry_run; then
  for v in "$V_PG" "$V_MEILI" "$V_DBURL"; do [[ "$v" =~ ^[0-9]+$ ]] || die "could not read back a new version number"; done
fi
log "S2: new versions: $SECRET_PG:$V_PG  $SECRET_MEILI:$V_MEILI  $SECRET_DBURL:$V_DBURL"
for s in "$SECRET_PG" "$SECRET_MEILI" "$SECRET_DBURL"; do grant "$s"; done
if ! is_dry_run; then
  for s in "$SECRET_PG" "$SECRET_MEILI" "$SECRET_DBURL"; do
    gc secrets get-iam-policy "$s" --format=json | python3 -c '
import json, sys
p = json.load(sys.stdin); m = "serviceAccount:" + sys.argv[1]
sys.exit(0 if any(b["role"] == "roles/secretmanager.secretAccessor" and m in b.get("members", []) for b in p.get("bindings", [])) else 1)' "$RUN_SA" ||
      die "accessor binding for $RUN_SA missing on $s"
  done
  log "S2: [OK] $RUN_SA can access all three secrets; waiting ${IAM_WAIT_SECONDS}s for IAM to propagate before the downtime window"
  sleep "$IAM_WAIT_SECONDS"
fi

# Install the VM helper (not secret; harmless) before anything that matters.
run gcloud compute scp "$HERE/vm/datastore-secrets.sh" "$HERE/vm/compose.template.yml" "$VM:/tmp/" \
  --zone "$ZONE" --project "$PROJECT" --quiet
run vm_ssh "sudo install -o root -g root -m 0700 /tmp/datastore-secrets.sh $HELPER && sudo install -o root -g root -m 0644 /tmp/compose.template.yml /opt/polarbear/compose.template.yml && rm -f /tmp/datastore-secrets.sh /tmp/compose.template.yml"
if ! is_dry_run; then
  vm_ssh "sudo $HELPER verify-template /opt/polarbear/compose.template.yml" 2>&1 | sed 's/^/    /' >&2 ||
    log "WARNING: compose.template.yml no longer matches the live compose.yml; update the template after this run"
fi

# ================================================================ recovery
META_CHANGED=0; VM_TOUCHED=0; RUN_CHANGED=0
rollback_35() {
  local problems="" restored="" p meta_now
  if [[ "$VM_TOUCHED" == 1 ]]; then
    log "ROLLBACK: VM -> old compose.yml, old Postgres password, docker compose up -d"
    if run vm_ssh "sudo $HELPER restore" 2>&1 | sed 's/^/    /' >&2; [[ "${PIPESTATUS[0]}" == 0 ]]; then
      restored="$restored|  VM: compose.yml, Postgres password and containers back on the pre-rotation values"
    else
      problems="$problems|  VM restore INCOMPLETE; the backup is kept at /opt/polarbear/compose.yml.pre-rotation. Finish with: gcloud compute ssh $VM --zone $ZONE --project $PROJECT --command 'sudo $HELPER restore'"
    fi
  fi
  if [[ "$RUN_CHANGED" == 1 || "$(serving_revision 2>/dev/null)" != "$START_REV" ]]; then
    log "ROLLBACK: Cloud Run traffic -> $START_REV"
    p=$(route_traffic_back "$START_REV")
    if [[ -z "$p" ]]; then restored="$restored|  Cloud Run: 100% of traffic on $START_REV (plaintext env with the OLD values)"
    else problems="$problems|  $p. By hand: gcloud run services update-traffic $RUN_SERVICE --region $RUN_REGION --project $PROJECT --to-revisions $START_REV=100"; fi
  fi
  if [[ "$META_CHANGED" == 1 ]]; then
    log "ROLLBACK: startup-script metadata -> the saved old value"
    run gc compute instances add-metadata "$VM" --zone "$ZONE" --metadata-from-file "startup-script=$OLD_META" >/dev/null 2>&1
    meta_now=$(gc compute instances describe "$VM" --zone "$ZONE" --format=json 2>/dev/null |
      python3 -c 'import json,sys,hashlib; m={i["key"]:i["value"] for i in json.load(sys.stdin)["metadata"].get("items",[])}; print(hashlib.sha256(m.get("startup-script","").encode()).hexdigest())' 2>/dev/null)
    if [[ -n "$meta_now" && "$meta_now" == "$(shasum -a 256 "$OLD_META" | awk '{print $1}')" ]]; then
      restored="$restored|  startup-script metadata: old value restored (it contains the LEAKED values again)"
    else
      keep_path "$PRIV"
      problems="$problems|  startup-script metadata NOT restored. The old value is saved at $OLD_META (0600; it CONTAINS THE LEAKED SECRETS; delete it after use). Restore: gcloud compute instances add-metadata $VM --zone $ZONE --project $PROJECT --metadata-from-file startup-script=$OLD_META"
    fi
  fi
  if [[ -z "$problems" ]]; then
    verify_production "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || problems="$problems|  production checks FAIL after the rollback; see the lines above"
  fi
  local title lines
  if [[ -z "$problems" ]]; then title="ROTATION ROLLED BACK — production is on the OLD (leaked) secrets again"
  else title="ROTATION ROLLBACK INCOMPLETE — act now"; fi
  lines="Restored:${restored:-|  (nothing)}"
  if [[ -n "$problems" ]]; then lines="$lines|NOT restored:$problems"; fi
  lines="$lines|Left behind (unused, harmless): Secret Manager versions $SECRET_PG:$V_PG, $SECRET_MEILI:$V_MEILI, $SECRET_DBURL:$V_DBURL."
  lines="$lines|  Disable them if you like: gcloud secrets versions disable <N> --secret <name> --project $PROJECT"
  if [[ -z "$problems" ]]; then
    lines="$lines|The leaked values are in service again, so rotation is STILL REQUIRED. Fix the cause, then re-run this script."
  else
    lines="$lines|The state is MIXED (see NOT restored), and production search may be DOWN. Finish the steps above first,"
    lines="$lines|then check: bash -c 'source $HERE/lib/common.sh; source $HERE/lib/verify-production.sh; verify_production && finish'"
  fi
  lines="$lines|Pre-rotation snapshot: $SNAP (runbook section C) if the VM itself is in a bad state."
  local IFS='|'
  # shellcheck disable=SC2086
  alarm "$title" $lines
}

# ================================================================ S3 metadata
gc compute instances describe "$VM" --zone "$ZONE" --format=json | python3 -c '
import json, sys
m = {i["key"]: i["value"] for i in json.load(sys.stdin)["metadata"].get("items", [])}
open(sys.argv[1], "w").write(m.get("startup-script", ""))' "$OLD_META"
chmod 600 "$OLD_META"
NEW_META_SHA=$(shasum -a 256 "$HERE/vm/startup-script.sh" | awk '{print $1}')
if [[ "$(shasum -a 256 "$OLD_META" | awk '{print $1}')" == "$NEW_META_SHA" ]]; then
  log "S3: startup-script metadata is already the secret-free version"
else
  [[ -s "$OLD_META" ]] || log "S3: note: there is no current startup-script to save"
  arm_recovery rollback_35                       # <- first mutation that matters comes next
  META_CHANGED=1
  run gc compute instances add-metadata "$VM" --zone "$ZONE" \
    --metadata-from-file "startup-script=$HERE/vm/startup-script.sh"
  if ! is_dry_run; then
    got=$(gc compute instances describe "$VM" --zone "$ZONE" --format=json |
      python3 -c 'import json,sys,hashlib; m={i["key"]:i["value"] for i in json.load(sys.stdin)["metadata"].get("items",[])}; print(hashlib.sha256(m.get("startup-script","").encode()).hexdigest())')
    [[ "$got" == "$NEW_META_SHA" ]] || { log "FAIL: startup-script metadata did not read back as vm/startup-script.sh"; exit 1; }
    log "S3: [OK] startup-script metadata is byte-identical to vm/startup-script.sh"
  fi
fi
if [[ -z "$_RECOVERY" ]] && ! is_dry_run; then arm_recovery rollback_35; fi   # S3 was skipped on a re-run

# ================================================================ S4 VM
VM_TOUCHED=1
if is_dry_run; then
  log "DRY-RUN would pipe the 2 new values on STDIN to: gcloud compute ssh $VM ... --command 'sudo $HELPER apply'"
  log "          (a. backup compose.yml  b. replace the 2 values  c. ALTER USER  d. docker compose up -d  e. wait healthy)"
else
  log "S4: rotating on the VM (planned downtime starts at step c)"
  printf '%s\n%s\n' "$NEW_PG" "$NEW_MEILI" | vm_ssh "sudo $HELPER apply" 2>&1 | sed 's/^/    /' >&2
  [[ "${PIPESTATUS[1]}" == 0 ]] || { log "FAIL: VM-side apply failed"; exit 1; }
fi

# ================================================================ S5 Cloud Run
RUN_CHANGED=1
S5_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run gc run services update "$RUN_SERVICE" --region "$RUN_REGION" \
  --remove-env-vars DATABASE_URL,MEILI_MASTER_KEY \
  --update-secrets "DATABASE_URL=$SECRET_DBURL:$V_DBURL,MEILI_MASTER_KEY=$SECRET_MEILI:$V_MEILI"

if is_dry_run; then
  log "(dry run) then: env diff (only DATABASE_URL, MEILI_MASTER_KEY may differ; both must be secret refs to the new versions),"
  log "          production checks, old-values-dead proofs, metadata counts, shred the VM backup."
  log "(dry run) baseline production checks now:"
  verify_production || log "baseline checks failed — production is unhealthy BEFORE any change"
  log "DRY RUN complete: nothing was changed"
  finish
fi

describe_service_json "$TMP/after.json"
env_hashes "$TMP/after.json" > "$TMP/after.hashes"; show_hashes "$TMP/after.hashes" "after"
env_diff "$TMP/before.hashes" "$TMP/after.hashes" "DATABASE_URL MEILI_MASTER_KEY" || { log "FAIL: an env var outside the allowed set changed"; exit 1; }
k1=$(env_kind "$TMP/after.json" DATABASE_URL); k2=$(env_kind "$TMP/after.json" MEILI_MASTER_KEY)
log "after: DATABASE_URL -> $k1; MEILI_MASTER_KEY -> $k2"
[[ "$k1" == "secret:$SECRET_DBURL:$V_DBURL" && "$k2" == "secret:$SECRET_MEILI:$V_MEILI" ]] ||
  { log "FAIL: the secret references are not pinned to the new versions"; exit 1; }

# ================================================================ S6 verify
log "S6: production checks on revision $(serving_revision)"
verify_production "$S5_START" || exit 1          # recovery armed: rolls back
disarm_recovery
log "S6: production serves on the NEW secrets; recovery disarmed (rolling back would re-enable the leaked values)"

proof=0
vm_ssh "sudo $HELPER prove-old-dead" 2>&1 | sed 's/^/    /' >&2; [[ "${PIPESTATUS[0]}" == 0 ]] || proof=1
counts=$(gc compute instances describe "$VM" --zone "$ZONE" --format=json |
  python3 -c 'import json,sys; m={i["key"]:i["value"] for i in json.load(sys.stdin)["metadata"].get("items",[])}; sys.stdout.write(m.get("startup-script",""))' |
  vm_ssh "sudo $HELPER count-in-stdin") || proof=1
log "S6: in the new startup-script metadata:"; printf '%s\n' "$counts" | sed 's/^/    /' >&2
if printf '%s\n' "$counts" | awk '{print $NF}' | grep -qv '^0$'; then proof=1; fi
if [[ "$proof" != 0 ]]; then
  alarm "ROTATION APPLIED, BUT A PROOF FAILED" \
    "Production works on the new secrets (checks passed); nothing was rolled back." \
    "One of: old key/password still accepted, or a secret value found in the startup-script metadata." \
    "The VM backup /opt/polarbear/compose.yml.pre-rotation is KEPT for investigation; shred it after:" \
    "  gcloud compute ssh $VM --zone $ZONE --project $PROJECT --command 'sudo $HELPER finish'"
  exit 1
fi

# ================================================================ S7
vm_ssh "sudo $HELPER finish" 2>&1 | sed 's/^/    /' >&2
# Mark the versions now in service, so rebuilds read exactly these (a rolled-back run can leave
# newer, unused versions behind, so "latest" would be wrong).
run gc secrets update "$SECRET_PG" --update-version-aliases "in-use=$V_PG" --format=none
run gc secrets update "$SECRET_MEILI" --update-version-aliases "in-use=$V_MEILI" --format=none
run gc secrets update "$SECRET_DBURL" --update-version-aliases "in-use=$V_DBURL" --format=none
log "DONE: rotated. Secrets pinned: $SECRET_DBURL:$V_DBURL, $SECRET_MEILI:$V_MEILI ($SECRET_PG:$V_PG for rebuilds)."
log "      Old values proven dead; startup-script is secret-free; snapshot $SNAP kept. Next: 30, then 40."
finish
