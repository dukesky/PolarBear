#!/usr/bin/env bash
# 35 — Rotate the Postgres password and Meilisearch master key into Secret Manager
#
# WHY: both values were exposed (2026-09-18), and the VM's startup-script held them in
# plaintext instance metadata, readable by any process on the VM without auth.
# Order: 10 and 20 have run -> 35 -> 30 -> 40. Script 30's reboot then proves this survives a boot.
#
# TWO PHASES
#   Phase 1 (no downtime) makes Cloud Run read DATABASE_URL and MEILI_MASTER_KEY from Secret Manager
#   while the VALUES stay the same. Phase 2 (the planned 2–3 min downtime) changes the values.
#   Nothing in phase 2 changes a variable's TYPE, so the only command in the window is a
#   documented same-group `--update-secrets` re-pin.
#
# CHANGES (in order)
#   S0  on-demand snapshot polarbear-services-pre-rotation-<UTC date> (waits for READY)
#   S2  Secret Manager: polarbear-postgres-password, polarbear-meili-master-key,
#       polarbear-database-url (full asyncpg URL). Created if missing (user-managed replica in
#       us-central1). The CURRENT DATABASE_URL and MEILI_MASTER_KEY, read from the serving revision,
#       are stored as versions ("old-value versions"), then the NEW values as newer versions. The Cloud
#       Run runtime SA gets roles/secretmanager.secretAccessor on EACH secret (resource level).
#   S2b PHASE 1, no downtime. `gcloud run services replace` with the service's own export, edited
#       ONLY so the two env vars become secret refs pinned to the old-value versions (validated
#       first with --dry-run). This is one documented, atomic operation; the cross-group
#       --remove-env-vars + --update-secrets ordering is undocumented, so it is not used.
#   S3  VM metadata `startup-script` -> vm/startup-script.sh (secret-free; never writes compose.yml)
#   S4  PHASE 2. On the VM (vm/datastore-secrets.sh apply): backup compose.yml, replace ONLY the
#       two values, ALTER USER, docker compose up -d, wait healthy.   <- planned downtime starts here
#   S5  Cloud Run: `--update-secrets` re-pins both refs to the NEW versions (same type, documented).
#                                                                 <- downtime ends when it serves
#   S7  after S6: `in-use` aliases -> new versions; DESTROY the old-value versions (verified DESTROYED);
#       shred the VM-side backup; delete the local copy of the old metadata.
#
# VERIFIES
#   S0 preflight: the backend is on 10.138.0.2 and 5432/7700 admit only 10.128.0.0/20 (refuses
#   otherwise); VM-side preflight (both keys present once, no leftover backup, Postgres
#   log_statement=none); the serving revision's values match the service template (by hash);
#   compose.template.yml still renders to the live compose.yml.
#   S2: each old-value version's payload hashes equal to the serving literal.
#   S2b: literal gone, secret ref pinned, payload hash == old literal hash, every other variable
#   byte-identical, production checks pass (values unchanged, so behaviour must be too).
#   After S3: the metadata reads back byte-identical to vm/startup-script.sh.
#   After S5: only DATABASE_URL and MEILI_MASTER_KEY differ, and both are refs to the exact NEW versions.
#   S6: production checks; then the OLD values are proven dead (Meilisearch rejects the old key,
#   Postgres rejects the old password over TCP/scram, each with the new value as a positive
#   control); then the startup-script metadata is shown to contain neither old nor new values.
#   S7: each destroyed version reads back as DESTROYED.
#
# ROLLS BACK
#   S2b failure (recovery rollback_s2b, armed only for S2b): Cloud Run traffic back to the
#   revision serving at start; the template is replaced with the ORIGINAL spec, traffic pinned to that
#   revision; the just-stored old-value versions are destroyed once nothing serving uses them.
#   NOTHING on the VM or in metadata has been touched, so that is the whole rollback.
#   Phase-2 failure (recovery rollback_35, armed right before S3): VM restored (compose.yml from the
#   backup, ALTER USER back, compose up); Cloud Run traffic back to the S2b revision, which already
#   uses secret refs to the OLD values, plus the template re-pinned to those versions with
#   --no-traffic; the old startup-script metadata restored. The NEW versions are left behind, unused,
#   and the old-value versions must be KEPT because they are in use again; the banner says so.
#   Once S6 passes, recovery is disarmed: rolling back after that would only re-enable leaked
#   values. That is also why destroying the old-value versions is safe exactly then.
#   A failed destroy or a failed proof after that point: loud banner with the exact commands, exit 1, no rollback.
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
python3 -c 'import yaml' 2>/dev/null || die "python3 needs PyYAML (pip3 install pyyaml): S2b edits the exported service spec"
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

# ================================================================ recovery for phase 1 (S2b)
# Defined BEFORE anything can arm it. Variables it reads are initialised here so `set -u` cannot abort it.
V_PG=""; V_MEILI=""; V_DBURL=""; OLD_V_DBURL=""; OLD_V_MEILI=""; S2B_REV="$START_REV"
rollback_s2b() {  # nothing on the VM has changed, so the rollback is Cloud Run only
  local p problems="" restored="" s v st
  # Only undo what actually changed: traffic if it moved, the template if its env differs from the start.
  if [[ "$(serving_revision 2>/dev/null)" == "$START_REV" ]]; then
    restored="$restored|  Cloud Run traffic: never moved; $START_REV serves 100% (plaintext env, values unchanged)"
  else
    log "ROLLBACK (S2b): Cloud Run traffic -> $START_REV"
    p=$(route_traffic_back "$START_REV")
    if [[ -z "$p" ]]; then restored="$restored|  Cloud Run: 100% of traffic on $START_REV (plaintext env, values unchanged)"
    else problems="$problems|  $p. By hand: gcloud run services update-traffic $RUN_SERVICE --region $RUN_REGION --project $PROJECT --to-revisions $START_REV=100"; fi
  fi
  local tmpl_same=0
  if describe_service_json "$TMP/rb.json" 2>/dev/null && env_hashes "$TMP/rb.json" > "$TMP/rb.hashes" 2>/dev/null &&
     cmp -s "$TMP/rb.hashes" "$TMP/before.hashes"; then tmpl_same=1; fi
  if [[ "$tmpl_same" == 1 ]]; then
    restored="$restored|  Cloud Run template: unchanged (still the original plaintext spec)"
  elif [[ -z "$problems" && -s "$TMP/svc-orig.yaml" ]]; then
    # Put the template back to the original spec with traffic PINNED to $START_REV, so the
    # re-created revision gets 0% and a re-run sees template == serving.
    python3 - "$TMP/svc-orig.yaml" "$TMP/svc-restore.yaml" "$START_REV" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
d["spec"]["traffic"] = [{"revisionName": sys.argv[3], "percent": 100}]
d["spec"]["template"].get("metadata", {}).pop("name", None)
yaml.safe_dump(d, open(sys.argv[2], "w"))
PY
    chmod 600 "$TMP/svc-restore.yaml"
    if run_shown_as "gcloud run services replace <0600 temp spec: the ORIGINAL spec, traffic pinned to $START_REV> --region $RUN_REGION" \
         gc run services replace "$TMP/svc-restore.yaml" --region "$RUN_REGION" >/dev/null &&
       [[ "$(serving_revision 2>/dev/null)" == "$START_REV" ]]; then
      restored="$restored|  Cloud Run template: back to the original plaintext spec (the re-created revision has 0% traffic)"
    else
      problems="$problems|  template NOT restored (traffic is on $START_REV). A re-run will refuse until the template matches the serving revision."
    fi
  else
    problems="$problems|  template differs from the start and could not be restored automatically"
  fi
  if [[ -z "$problems" ]]; then
    verify_production "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || problems="$problems|  production checks FAIL on $START_REV"
  fi
  # The current-value versions stored in S2b hold the LEAKED values. They can go once nothing serving references them.
  local destroy_msg="" manual=""
  for sv in "$SECRET_DBURL:$OLD_V_DBURL" "$SECRET_MEILI:$OLD_V_MEILI"; do
    s=${sv%%:*}; v=${sv##*:}
    [[ "$v" =~ ^[0-9]+$ ]] || continue
    if [[ -z "$problems" ]] && run gc secrets versions destroy "$v" --secret "$s" --format=none >/dev/null 2>&1 &&
       [[ "$(gc secrets versions describe "$v" --secret "$s" --format='value(state)' 2>/dev/null)" == DESTROYED ]]; then
      destroy_msg="$destroy_msg $s:$v"
    else
      manual="$manual|    gcloud secrets versions destroy $v --secret $s --project $PROJECT"
    fi
  done
  local lines="NOTHING on the VM was changed; the startup-script was not touched.|Restored:${restored:-|  (nothing)}"
  if [[ -n "$problems" ]]; then lines="$lines|NOT restored:$problems"; fi
  if [[ -n "$destroy_msg" ]]; then lines="$lines|Destroyed (they held the current, leaked values):$destroy_msg"; fi
  if [[ -n "$manual" ]]; then lines="$lines|DESTROY BY HAND once traffic is confirmed on $START_REV (they hold the current, leaked values):$manual"; fi
  lines="$lines|Left behind (unused, never in service): NEW versions $SECRET_PG:$V_PG, $SECRET_MEILI:$V_MEILI, $SECRET_DBURL:$V_DBURL."
  lines="$lines|Rotation is STILL REQUIRED. Fix the cause, then re-run this script."
  local IFS='|'
  # shellcheck disable=SC2086
  alarm "$( [[ -z "$problems" ]] && echo "S2b FAILED — rolled back; production unchanged on $START_REV" || echo "S2b ROLLBACK INCOMPLETE — act now")" $lines
}

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
version_sha() {  # version_sha SECRET VERSION: SHA-256 of the stored payload, never printed.
  # --out-file writes the RAW bytes (stdout would be re-encoded as UTF-8), into a 0600 temp file removed at once.
  local f h
  f=$(mktemp "$TMP/.payload.XXXXXX")
  gc secrets versions access "$2" --secret "$1" --out-file "$f" >/dev/null
  h=$(shasum -a 256 "$f" | awk '{print $1}'); rm -f "$f"; echo "$h"
}
full_hash() { awk -v n="$2" '$1 == n {print $2}' "$1"; }   # full_hash HASHFILE NAME
in_use_alias() {  # the version currently aliased in-use, if any (re-runs)
  gc secrets describe "$1" --format=json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("versionAliases",{}).get("in-use",""))' 2>/dev/null || true
}
for s in "$SECRET_PG" "$SECRET_MEILI" "$SECRET_DBURL"; do ensure_secret "$s"; done

# Where are DATABASE_URL / MEILI_MASTER_KEY today? Both literal (first run) or both refs (a re-run).
k_db=$(env_kind "$TMP/start.json" DATABASE_URL); k_me=$(env_kind "$TMP/start.json" MEILI_MASTER_KEY)
OLD_V_PG=""
if [[ "$k_db" == literal && "$k_me" == literal ]]; then
  CONVERT=1; OLD_V_DBURL="<N>"; OLD_V_MEILI="<N>"
elif [[ "$k_db" == "secret:$SECRET_DBURL:"* && "$k_me" == "secret:$SECRET_MEILI:"* ]]; then
  CONVERT=0; OLD_V_DBURL=${k_db##*:}; OLD_V_MEILI=${k_me##*:}; OLD_V_PG=$(in_use_alias "$SECRET_PG")
  log "S2b: already secret references ($SECRET_DBURL:$OLD_V_DBURL, $SECRET_MEILI:$OLD_V_MEILI); no conversion needed"
else
  die "DATABASE_URL ($k_db) and MEILI_MASTER_KEY ($k_me) must be both literal or both refs to $SECRET_DBURL/$SECRET_MEILI"
fi

if [[ "$CONVERT" == 1 ]]; then
  # The CURRENT values, read from the SERVING revision into variables that are never printed.
  gc run revisions describe "$START_REV" --region "$RUN_REGION" --format=json > "$TMP/startrev.json"; chmod 600 "$TMP/startrev.json"
  get_rev_env() {  # get_rev_env NAME: the literal value, to STDOUT for $(...) capture only
    python3 - "$TMP/startrev.json" "$1" <<'PY'
import json, sys
env = {e["name"]: e for e in json.load(open(sys.argv[1]))["spec"]["containers"][0].get("env", [])}
e = env.get(sys.argv[2], {})
if "value" not in e: sys.exit("not a literal in the serving revision: " + sys.argv[2])
sys.stdout.write(e["value"])
PY
  }
  # Read-only, so it also runs in a dry run. The values stay in variables and are never printed.
  if true; then
    CUR_DBURL=$(get_rev_env DATABASE_URL); CUR_MEILI=$(get_rev_env MEILI_MASTER_KEY)
    # The serving revision must hold exactly what the template holds, or the export we convert is not what serves.
    [[ "$(printf '%s' "$CUR_DBURL" | shasum -a 256 | awk '{print $1}')" == "$(full_hash "$TMP/before.hashes" DATABASE_URL)" &&
       "$(printf '%s' "$CUR_MEILI" | shasum -a 256 | awk '{print $1}')" == "$(full_hash "$TMP/before.hashes" MEILI_MASTER_KEY)" ]] ||
      die "the serving revision $START_REV and the service template disagree on DATABASE_URL/MEILI_MASTER_KEY; reconcile first"
    log "S2b: [OK] the serving revision $START_REV holds the same DATABASE_URL/MEILI_MASTER_KEY as the template (by hash)"
  fi
  OLD_V_DBURL=$(add_version "$SECRET_DBURL" "$CUR_DBURL")
  OLD_V_MEILI=$(add_version "$SECRET_MEILI" "$CUR_MEILI")
  unset CUR_DBURL CUR_MEILI
  # From here the leaked values also sit in Secret Manager, so any failure must clean them up.
  if ! is_dry_run; then arm_recovery rollback_s2b; fi
  log "S2b: CURRENT values stored as $SECRET_DBURL:$OLD_V_DBURL and $SECRET_MEILI:$OLD_V_MEILI (destroyed after a successful rotation)"
fi

V_PG=$(add_version "$SECRET_PG" "$NEW_PG")
V_MEILI=$(add_version "$SECRET_MEILI" "$NEW_MEILI")
V_DBURL=$(add_version "$SECRET_DBURL" "$NEW_DBURL")
if ! is_dry_run; then
  for v in "$V_PG" "$V_MEILI" "$V_DBURL" "$OLD_V_DBURL" "$OLD_V_MEILI"; do [[ "$v" =~ ^[0-9]+$ ]] || die "could not read back a version number"; done
fi
log "S2: NEW versions: $SECRET_PG:$V_PG  $SECRET_MEILI:$V_MEILI  $SECRET_DBURL:$V_DBURL"
for s in "$SECRET_PG" "$SECRET_MEILI" "$SECRET_DBURL"; do grant "$s"; done
if ! is_dry_run; then
  for s in "$SECRET_PG" "$SECRET_MEILI" "$SECRET_DBURL"; do
    gc secrets get-iam-policy "$s" --format=json | python3 -c '
import json, sys
p = json.load(sys.stdin); m = "serviceAccount:" + sys.argv[1]
sys.exit(0 if any(b["role"] == "roles/secretmanager.secretAccessor" and m in b.get("members", []) for b in p.get("bindings", [])) else 1)' "$RUN_SA" ||
      die "accessor binding for $RUN_SA missing on $s"
  done
  if [[ "$CONVERT" == 1 ]]; then
    [[ "$(version_sha "$SECRET_DBURL" "$OLD_V_DBURL")" == "$(full_hash "$TMP/before.hashes" DATABASE_URL)" &&
       "$(version_sha "$SECRET_MEILI" "$OLD_V_MEILI")" == "$(full_hash "$TMP/before.hashes" MEILI_MASTER_KEY)" ]] ||
      die "a stored current-value version does not hash-match the serving value"
    log "S2b: [OK] stored current-value versions hash-match the serving values"
  fi
  log "S2: [OK] $RUN_SA can access all three secrets; waiting ${IAM_WAIT_SECONDS}s for IAM to propagate"
  sleep "$IAM_WAIT_SECONDS"
fi

# ================================================================ S2b convert (no downtime)
# `gcloud run services replace` with the service's OWN export, edited only in the two env entries:
# one atomic, documented operation ("create or replace a service from a YAML spec"). It does NOT
# rely on the undocumented cross-group ordering of --remove-env-vars plus --update-secrets.
# The values do not change, so production must behave exactly as before.
cp "$TMP/before.hashes" "$TMP/s2b.hashes"

if [[ "$CONVERT" == 1 ]]; then
  log "S2b: converting DATABASE_URL and MEILI_MASTER_KEY to secret references with the SAME values (no downtime)"
  if is_dry_run; then
    log "(dry run) would arm recovery: rollback_s2b"
    # Read-only rehearsal: export the real service and build the converted spec locally (0600, deleted on exit).
    gc run services describe "$RUN_SERVICE" --region "$RUN_REGION" --format=export > "$TMP/svc-orig.yaml"; chmod 600 "$TMP/svc-orig.yaml"
    python3 - "$TMP/svc-orig.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
env = d["spec"]["template"]["spec"]["containers"][0]["env"]
lit = [e["name"] for e in env if e["name"] in ("DATABASE_URL", "MEILI_MASTER_KEY") and "value" in e]
for e in env:
    if e["name"] in lit:
        del e["value"]; e["valueFrom"] = {"secretKeyRef": {"name": "x", "key": "1"}}
refs = [e["name"] for e in env if "valueFrom" in e]
others = [e["name"] for e in env if "value" in e]
print("S2b rehearsal: export parsed; %d env vars; would convert %s; afterwards secret refs=%s, literals kept=%d" % (
      len(env), sorted(lit), sorted(refs), len(others)), file=sys.stderr)
sys.exit(0 if sorted(lit) == ["DATABASE_URL", "MEILI_MASTER_KEY"] else 1)
PY
    rm -f "$TMP/svc-orig.yaml"
    log "DRY-RUN would run: gcloud run services describe $RUN_SERVICE --format=export  ->  0600 temp spec, edited ONLY in:"
    log "          DATABASE_URL -> secretKeyRef $SECRET_DBURL:<N>, MEILI_MASTER_KEY -> secretKeyRef $SECRET_MEILI:<N>, traffic -> latest 100%"
    log "DRY-RUN would run: gcloud run services replace <that spec> --region $RUN_REGION --dry-run   (server-side validation)"
    log "DRY-RUN would run: gcloud run services replace <that spec> --region $RUN_REGION"
    log "          then verify: env vars gone, refs pinned, each ref's payload hash == the old literal's hash, all else identical, production checks"
  else
    gc run services describe "$RUN_SERVICE" --region "$RUN_REGION" --format=export > "$TMP/svc-orig.yaml"; chmod 600 "$TMP/svc-orig.yaml"
    python3 - "$TMP/svc-orig.yaml" "$TMP/svc-s2b.yaml" "$SECRET_DBURL" "$OLD_V_DBURL" "$SECRET_MEILI" "$OLD_V_MEILI" <<'PY'
import sys, yaml
src, out, s_db, v_db, s_me, v_me = sys.argv[1:7]
d = yaml.safe_load(open(src))
refs = {"DATABASE_URL": (s_db, v_db), "MEILI_MASTER_KEY": (s_me, v_me)}
env = d["spec"]["template"]["spec"]["containers"][0]["env"]
done = set()
for e in env:
    if e["name"] in refs:
        if "value" not in e: sys.exit("%s is not a literal in the export" % e["name"])
        del e["value"]
        e["valueFrom"] = {"secretKeyRef": {"name": refs[e["name"]][0], "key": refs[e["name"]][1]}}
        done.add(e["name"])
if done != set(refs): sys.exit("export is missing %s" % (set(refs) - done))
d["spec"]["template"].get("metadata", {}).pop("name", None)   # let Cloud Run name the new revision
d["spec"]["traffic"] = [{"latestRevision": True, "percent": 100}]
yaml.safe_dump(d, open(out, "w"))
PY
    chmod 600 "$TMP/svc-s2b.yaml"
    run_shown_as "gcloud run services replace <0600 temp spec: exported service with 2 env entries -> secret refs> --region $RUN_REGION --dry-run" \
      gc run services replace "$TMP/svc-s2b.yaml" --region "$RUN_REGION" --dry-run >/dev/null
    log "S2b: [OK] server-side --dry-run validation passed"
    run_shown_as "gcloud run services replace <0600 temp spec: exported service with 2 env entries -> secret refs> --region $RUN_REGION" \
      gc run services replace "$TMP/svc-s2b.yaml" --region "$RUN_REGION" >/dev/null
    rm -f "$TMP/svc-s2b.yaml"
    # Explicit verification of the result.
    describe_service_json "$TMP/s2b.json"
    env_hashes "$TMP/s2b.json" > "$TMP/s2b.hashes"; show_hashes "$TMP/s2b.hashes" "after S2b"
    env_diff "$TMP/before.hashes" "$TMP/s2b.hashes" "DATABASE_URL MEILI_MASTER_KEY" || { log "FAIL: S2b changed something else"; exit 1; }
    [[ "$(env_kind "$TMP/s2b.json" DATABASE_URL)" == "secret:$SECRET_DBURL:$OLD_V_DBURL" &&
       "$(env_kind "$TMP/s2b.json" MEILI_MASTER_KEY)" == "secret:$SECRET_MEILI:$OLD_V_MEILI" ]] ||
      { log "FAIL: after S2b the variables are not secret refs to $SECRET_DBURL:$OLD_V_DBURL / $SECRET_MEILI:$OLD_V_MEILI"; exit 1; }
    [[ "$(version_sha "$SECRET_DBURL" "$OLD_V_DBURL")" == "$(full_hash "$TMP/before.hashes" DATABASE_URL)" &&
       "$(version_sha "$SECRET_MEILI" "$OLD_V_MEILI")" == "$(full_hash "$TMP/before.hashes" MEILI_MASTER_KEY)" ]] ||
      { log "FAIL: a referenced version's payload does not hash-match the old literal value"; exit 1; }
    log "S2b: [OK] env vars converted: literal gone, refs pinned, same values by hash, everything else byte-identical"
    S2B_REV=$(serving_revision)
    [[ -n "$S2B_REV" && "$S2B_REV" != "$START_REV" ]] || { log "FAIL: no new revision is serving after S2b"; exit 1; }
    verify_production "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || exit 1
    disarm_recovery
    log "S2b: [OK] production unchanged on $S2B_REV (secret refs, same values). Rollback target for the downtime window: $S2B_REV"
  fi
fi

# Install the VM helper (not secret; harmless) before anything that matters.
run gcloud compute scp "$HERE/vm/datastore-secrets.sh" "$HERE/vm/compose.template.yml" "$VM:/tmp/" \
  --zone "$ZONE" --project "$PROJECT" --quiet
run vm_ssh "sudo install -o root -g root -m 0700 /tmp/datastore-secrets.sh $HELPER && sudo install -o root -g root -m 0644 /tmp/compose.template.yml /opt/polarbear/compose.template.yml && rm -f /tmp/datastore-secrets.sh /tmp/compose.template.yml"
if ! is_dry_run; then
  vm_ssh "sudo $HELPER verify-template /opt/polarbear/compose.template.yml" 2>&1 | sed 's/^/    /' >&2 ||
    log "WARNING: compose.template.yml no longer matches the live compose.yml; update the template after this run"
fi

# ================================================================ recovery for the downtime window
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
  if [[ "$RUN_CHANGED" == 1 || "$(serving_revision 2>/dev/null)" != "$S2B_REV" ]]; then
    log "ROLLBACK: Cloud Run traffic -> $S2B_REV"
    p=$(route_traffic_back "$S2B_REV")
    if [[ -z "$p" ]]; then
      restored="$restored|  Cloud Run: 100% of traffic on $S2B_REV (secret refs $SECRET_DBURL:$OLD_V_DBURL, $SECRET_MEILI:$OLD_V_MEILI = the OLD values)"
      # Re-pin the template to the OLD versions without moving traffic (same-group update, --no-traffic),
      # so the template matches what serves and a re-run starts from a consistent state.
      if [[ "$RUN_CHANGED" == 1 ]]; then
        if run gc run services update "$RUN_SERVICE" --region "$RUN_REGION" --no-traffic \
             --update-secrets "DATABASE_URL=$SECRET_DBURL:$OLD_V_DBURL,MEILI_MASTER_KEY=$SECRET_MEILI:$OLD_V_MEILI" >/dev/null 2>&1 &&
           [[ "$(serving_revision 2>/dev/null)" == "$S2B_REV" ]]; then
          restored="$restored|  Cloud Run template: re-pinned to the OLD versions (new revision created with 0% traffic)"
        else
          problems="$problems|  template still pinned to the NEW versions (traffic is fine on $S2B_REV). Before a re-run: gcloud run services update $RUN_SERVICE --region $RUN_REGION --project $PROJECT --no-traffic --update-secrets DATABASE_URL=$SECRET_DBURL:$OLD_V_DBURL,MEILI_MASTER_KEY=$SECRET_MEILI:$OLD_V_MEILI"
        fi
      fi
    else problems="$problems|  $p. By hand: gcloud run services update-traffic $RUN_SERVICE --region $RUN_REGION --project $PROJECT --to-revisions $S2B_REV=100"; fi
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
  lines="$lines|IN USE AGAIN — do NOT destroy until a rotation succeeds: $SECRET_DBURL:$OLD_V_DBURL, $SECRET_MEILI:$OLD_V_MEILI (they hold the old values)."
  lines="$lines|Left behind (unused, never in service): NEW versions $SECRET_PG:$V_PG, $SECRET_MEILI:$V_MEILI, $SECRET_DBURL:$V_DBURL."
  lines="$lines|  Disable or destroy them if you like: gcloud secrets versions destroy <N> --secret <name> --project $PROJECT"
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
  arm_recovery rollback_35                       # <- first mutation of the downtime phase comes next
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

# ================================================================ S5 Cloud Run (same-type re-pin)
# Both variables are already secret refs (S2b), so this is a documented same-group update.
RUN_CHANGED=1
S5_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run gc run services update "$RUN_SERVICE" --region "$RUN_REGION" \
  --update-secrets "DATABASE_URL=$SECRET_DBURL:$V_DBURL,MEILI_MASTER_KEY=$SECRET_MEILI:$V_MEILI"

if is_dry_run; then
  log "(dry run) then: env diff vs S2b (only DATABASE_URL, MEILI_MASTER_KEY may differ; refs pinned to the NEW versions),"
  log "          production checks, recovery disarmed, aliases -> new, DESTROY $SECRET_DBURL:<old>, $SECRET_MEILI:<old> (verify DESTROYED),"
  log "          old-values-dead proofs, metadata counts, shred the VM backup."
  log "(dry run) baseline production checks now:"
  verify_production || log "baseline checks failed — production is unhealthy BEFORE any change"
  log "DRY RUN complete: nothing was changed"
  finish
fi

describe_service_json "$TMP/after.json"
env_hashes "$TMP/after.json" > "$TMP/after.hashes"; show_hashes "$TMP/after.hashes" "after"
env_diff "$TMP/s2b.hashes" "$TMP/after.hashes" "DATABASE_URL MEILI_MASTER_KEY" || { log "FAIL: an env var outside the allowed set changed"; exit 1; }
env_diff "$TMP/before.hashes" "$TMP/after.hashes" "DATABASE_URL MEILI_MASTER_KEY" || { log "FAIL: vs the start, an env var outside the allowed set changed"; exit 1; }
k1=$(env_kind "$TMP/after.json" DATABASE_URL); k2=$(env_kind "$TMP/after.json" MEILI_MASTER_KEY)
log "after: DATABASE_URL -> $k1; MEILI_MASTER_KEY -> $k2"
[[ "$k1" == "secret:$SECRET_DBURL:$V_DBURL" && "$k2" == "secret:$SECRET_MEILI:$V_MEILI" ]] ||
  { log "FAIL: the secret references are not pinned to the new versions"; exit 1; }

# ================================================================ S6 verify
log "S6: production checks on revision $(serving_revision)"
verify_production "$S5_START" || exit 1          # recovery armed: rolls back to $S2B_REV
disarm_recovery
log "S6: production serves on the NEW secrets; recovery disarmed (from here, rolling back would only re-enable the leaked values)"

# ================================================================ S7 aliases, destroy old versions, proofs, cleanup
# Order matters: aliases move to the new versions first (an aliased version is never the one destroyed),
# and the destroy only runs now that no automated rollback can route back to the old versions.
run gc secrets update "$SECRET_PG" --update-version-aliases "in-use=$V_PG" --format=none
run gc secrets update "$SECRET_MEILI" --update-version-aliases "in-use=$V_MEILI" --format=none
run gc secrets update "$SECRET_DBURL" --update-version-aliases "in-use=$V_DBURL" --format=none

DESTROY_FAILED=""
destroyed=""
for sv in "$SECRET_DBURL:$OLD_V_DBURL" "$SECRET_MEILI:$OLD_V_MEILI" "$SECRET_PG:$OLD_V_PG"; do
  s=${sv%%:*}; v=${sv##*:}
  [[ -n "$v" ]] || continue
  if run gc secrets versions destroy "$v" --secret "$s" --format=none &&
     [[ "$(gc secrets versions describe "$v" --secret "$s" --format='value(state)')" == DESTROYED ]]; then
    destroyed="$destroyed $s:$v"
  else
    DESTROY_FAILED="$DESTROY_FAILED|  gcloud secrets versions destroy $v --secret $s --project $PROJECT"
  fi
done
if [[ -n "$destroyed" ]]; then log "S7: [OK] old-value versions DESTROYED:$destroyed"; fi

proof=0
vm_ssh "sudo $HELPER prove-old-dead" 2>&1 | sed 's/^/    /' >&2; [[ "${PIPESTATUS[0]}" == 0 ]] || proof=1
counts=$(gc compute instances describe "$VM" --zone "$ZONE" --format=json |
  python3 -c 'import json,sys; m={i["key"]:i["value"] for i in json.load(sys.stdin)["metadata"].get("items",[])}; sys.stdout.write(m.get("startup-script",""))' |
  vm_ssh "sudo $HELPER count-in-stdin") || proof=1
log "S6: in the new startup-script metadata:"; printf '%s\n' "$counts" | sed 's/^/    /' >&2
if printf '%s\n' "$counts" | awk '{print $NF}' | grep -qv '^0$'; then proof=1; fi

failed=0
if [[ -n "$DESTROY_FAILED" ]]; then
  failed=1
  (IFS='|'
   # shellcheck disable=SC2086
   alarm "OLD SECRET VERSIONS NOT DESTROYED — the leaked values are still stored in Secret Manager" \
     "Production is FINE on the new secrets. No SERVING revision references these versions (older, idle revisions do; never route traffic back to them)." \
     "Destroy them by hand now (irreversible, and that is the point):" ${DESTROY_FAILED#|} \
     "Then confirm: gcloud secrets versions list <secret> --project $PROJECT   (state must be DESTROYED)")
fi
if [[ "$proof" != 0 ]]; then
  failed=1
  alarm "ROTATION APPLIED, BUT A PROOF FAILED" \
    "Production works on the new secrets (checks passed); nothing was rolled back." \
    "One of: old key/password still accepted, or a secret value found in the startup-script metadata." \
    "The VM backup /opt/polarbear/compose.yml.pre-rotation is KEPT for investigation; shred it after:" \
    "  gcloud compute ssh $VM --zone $ZONE --project $PROJECT --command 'sudo $HELPER finish'"
else
  vm_ssh "sudo $HELPER finish" 2>&1 | sed 's/^/    /' >&2
fi
if [[ "$failed" != 0 ]]; then exit 1; fi
log "DONE: rotated. Pinned: $SECRET_DBURL:$V_DBURL, $SECRET_MEILI:$V_MEILI ($SECRET_PG:$V_PG for rebuilds); alias in-use moved."
log "      Old-value versions destroyed; old values proven dead; startup-script secret-free; snapshot $SNAP kept. Next: 30, then 40."
finish
