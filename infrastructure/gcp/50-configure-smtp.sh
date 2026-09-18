#!/usr/bin/env bash
# 50 — Send password-reset email through Gmail SMTP
#
# PRECONDITION (the owner does this, by hand, BEFORE running): create the secret
# `polarbear-smtp-password` in Secret Manager, holding a Gmail APP PASSWORD for the sending
# account (Google Account -> Security -> 2-Step Verification -> App passwords). For example:
#     gcloud secrets create polarbear-smtp-password --replication-policy user-managed \
#       --locations us-central1 --project polarbear-dev-479000
#     gcloud secrets versions add polarbear-smtp-password --data-file=- --project polarbear-dev-479000
#     (paste the app password, then Ctrl-D)
# This script never asks for, reads, prints or handles that value. It only checks that the
# secret exists and has an enabled version.
#
# CHANGES
#   - roles/secretmanager.secretAccessor on polarbear-smtp-password (that one secret only) for
#     the Cloud Run runtime service account
#   - Cloud Run polarbear-backend, ONE update: SMTP_HOST=smtp.gmail.com, SMTP_PORT=587,
#     SMTP_TLS=true, SMTP_USER=<address>, SMTP_FROM=<address>, and SMTP_PASSWORD as a secret
#     reference PINNED to the newest enabled version number.
#
# VERIFIES
#   Per-variable SHA-256: nothing outside SMTP_* may differ. SMTP_PASSWORD must be the pinned
#   secret ref. Then the shared production checks. Egress: Cloud Run uses private-ranges-only, so
#   smtp.gmail.com:587 goes out directly, not through the VPC. The script also confirms no VPC
#   EGRESS firewall rule exists that could matter (10/20 only changed INGRESS rules).
#   Optional --send-test-to EMAIL: checks (read-only, prints yes/no only) that EMAIL is a
#   registered, active user. Only then does it POST /auth/forgot-password and read the backend's
#   logs for that request. The backend logs NOTHING on a successful send, and on failure logs
#   "[email] failed to send to <addr>: <error>". So a clean result means "no SMTP error", not "delivered":
#   check the inbox. Log lines are COUNTED, never printed: with SMTP unconfigured the backend
#   logs the whole message, reset token included.
#
# ROLLS BACK
#   Recovery is armed before the Cloud Run update. Any exit before the checks pass routes 100%
#   of traffic back to the revision that served at start and prints what is and is not
#   restored. The IAM binding is left in place (harmless).
#
# Usage:  DRY_RUN=1 ./50-configure-smtp.sh sender@gmail.com [--send-test-to someone@example.com]
#         ./50-configure-smtp.sh sender@gmail.com [--send-test-to someone@example.com]
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/verify-production.sh
source "$HERE/lib/verify-production.sh"
# shellcheck source=lib/cloudrun.sh
source "$HERE/lib/cloudrun.sh"

: "${SMTP_SECRET:=polarbear-smtp-password}"
: "${SMTP_HOST_VALUE:=smtp.gmail.com}"
: "${SMTP_PORT_VALUE:=587}"
: "${TEST_LOG_WAIT:=30}"

EMAIL_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
SENDER=""; TEST_TO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --send-test-to) TEST_TO=${2:-}; shift 2 ;;
    -*) die "unknown option $1" ;;
    *) [[ -z "$SENDER" ]] || die "only one sender address"; SENDER=$1; shift ;;
  esac
done
[[ -n "$SENDER" ]] || die "usage: $0 SENDER_GMAIL_ADDRESS [--send-test-to EMAIL]   (no default)"
[[ "$SENDER" =~ $EMAIL_RE ]] || die "'$SENDER' does not look like an email address"
[[ -z "$TEST_TO" || "$TEST_TO" =~ $EMAIL_RE ]] || die "'$TEST_TO' does not look like an email address"

require gcloud python3 curl
banner "50: SMTP via $SMTP_HOST_VALUE:$SMTP_PORT_VALUE as $SENDER"
TMP=$(mktemp -d); add_cleanup "$TMP"

# ---------------------------------------------------------------- preflight
if ! gc secrets describe "$SMTP_SECRET" --format='value(name)' >/dev/null 2>&1; then
  msg="secret $SMTP_SECRET does not exist; the owner must create it first (see the header)"
  if is_dry_run; then log "preflight: [WOULD REFUSE] $msg (continuing only because DRY_RUN=1)"; else die "$msg"; fi
  V_SMTP="<N>"
else
  V_SMTP=$(gc secrets versions list "$SMTP_SECRET" --filter='state:ENABLED' --sort-by='~createTime' --limit 1 --format='value(name)')
  V_SMTP=${V_SMTP##*/}
  [[ "$V_SMTP" =~ ^[0-9]+$ ]] || die "secret $SMTP_SECRET has no ENABLED version"
  log "preflight: [OK] $SMTP_SECRET exists; newest enabled version = $V_SMTP (value not read)"
fi
egress=$(gc compute firewall-rules list --filter="direction=EGRESS AND network~/$VPC_NETWORK\$" --format='value(name)')
if [[ -z "$egress" ]]; then log "preflight: [OK] no EGRESS firewall rules in $VPC_NETWORK; 10/20 changed only INGRESS rules"
else log "preflight: NOTE egress rules exist ($egress). Cloud Run private-ranges-only sends smtp.gmail.com traffic direct, not via the VPC, so they do not apply"; fi

RUN_SA=$(runtime_service_account); log "preflight: runtime service account $RUN_SA"
START_REV=$(serving_revision); [[ -n "$START_REV" ]] || die "cannot read the serving revision"
log "preflight: serving revision $START_REV (rollback target)"
describe_service_json "$TMP/before.json"
env_hashes "$TMP/before.json" > "$TMP/before.hashes"; show_hashes "$TMP/before.hashes" "before"
ann=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["spec"]["template"]["metadata"].get("annotations",{}).get("run.googleapis.com/vpc-access-egress",""))' "$TMP/before.json")
log "preflight: Cloud Run vpc-access-egress = ${ann:-unset} (private-ranges-only => public SMTP goes direct)"

# ---------------------------------------------------------------- change
run gc secrets add-iam-policy-binding "$SMTP_SECRET" --member "serviceAccount:$RUN_SA" \
  --role roles/secretmanager.secretAccessor --format=none

rollback_50() {
  local p
  log "ROLLBACK: Cloud Run traffic -> $START_REV"
  p=$(route_traffic_back "$START_REV")
  if [[ -z "$p" ]] && verify_production "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
    alarm "SMTP CHANGE ROLLED BACK — $START_REV serves again (no SMTP config)" \
      "Traffic is pinned to $START_REV; the template keeps the new SMTP settings." \
      "Fix the cause and re-run, or: gcloud run services update-traffic $RUN_SERVICE --to-latest --region $RUN_REGION --project $PROJECT"
  else
    alarm "SMTP ROLLBACK INCOMPLETE — act now" "${p:-production checks fail on $START_REV}" \
      "By hand: gcloud run services update-traffic $RUN_SERVICE --region $RUN_REGION --project $PROJECT --to-revisions $START_REV=100"
  fi
}
arm_recovery rollback_50
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run gc run services update "$RUN_SERVICE" --region "$RUN_REGION" \
  --update-env-vars "SMTP_HOST=$SMTP_HOST_VALUE,SMTP_PORT=$SMTP_PORT_VALUE,SMTP_TLS=true,SMTP_USER=$SENDER,SMTP_FROM=$SENDER" \
  --update-secrets "SMTP_PASSWORD=$SMTP_SECRET:$V_SMTP"

if is_dry_run; then
  log "(dry run) then: env diff (only SMTP_* may differ; SMTP_PASSWORD must be secret:$SMTP_SECRET:$V_SMTP), production checks."
  verify_production || log "baseline checks failed — production is unhealthy BEFORE any change"
else
  describe_service_json "$TMP/after.json"
  env_hashes "$TMP/after.json" > "$TMP/after.hashes"; show_hashes "$TMP/after.hashes" "after"
  env_diff "$TMP/before.hashes" "$TMP/after.hashes" "SMTP_HOST SMTP_PORT SMTP_TLS SMTP_USER SMTP_FROM SMTP_PASSWORD" ||
    { log "FAIL: an env var outside SMTP_* changed"; exit 1; }
  k=$(env_kind "$TMP/after.json" SMTP_PASSWORD); log "after: SMTP_PASSWORD -> $k"
  [[ "$k" == "secret:$SMTP_SECRET:$V_SMTP" ]] || { log "FAIL: SMTP_PASSWORD is not pinned to $SMTP_SECRET:$V_SMTP"; exit 1; }
  verify_production "$since" || exit 1
  disarm_recovery
  log "DONE: SMTP configured on revision $(serving_revision)"
fi

# ---------------------------------------------------------------- optional test send
if [[ -z "$TEST_TO" ]]; then
  if is_dry_run; then log "DRY RUN complete: nothing was changed"; fi
  finish
fi
log "test: is $TEST_TO a registered, active user? (read-only query; prints yes/no only)"
# The address reaches psql as a variable (-v), and the SQL arrives on stdin. It is already validated against EMAIL_RE.
n=$(printf '%s\n' "select count(*) from \"user\" where lower(email) = lower(:'addr') and is_active;" |
    vm_ssh "sudo docker exec -i $PG_CONTAINER psql -U $PG_USER -d $PG_DB -At -v addr=$TEST_TO" 2>/dev/null | tr -d '[:space:]') || n=""
case "$n" in
  0)  log "test: registered = no"
      log "test: CANNOT PROVE ANYTHING: forgot-password answers 202 for unknown addresses and sends nothing."
      log "      Register $TEST_TO in the app first, or pick a registered address."
      if is_dry_run; then log "DRY RUN complete: nothing was changed"; fi
      finish ;;
  ''|*[!0-9]*) die "test: could not check registration" ;;
  *)  log "test: registered = yes" ;;
esac
url=$(backend_url)
if is_dry_run; then
  log "DRY-RUN would run: POST $url/auth/forgot-password {\"email\": \"$TEST_TO\"}, wait ${TEST_LOG_WAIT}s, then count SMTP error lines"
  log "DRY RUN complete: nothing was changed"; finish
fi
t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -H 'Content-Type: application/json' \
  -d "{\"email\": \"$TEST_TO\"}" "$url/auth/forgot-password" 2>/dev/null) || true
log "test: POST /auth/forgot-password -> ${code:-000} (202 is expected either way, by design)"
log "test: waiting ${TEST_LOG_WAIT}s for logs"; sleep "$TEST_LOG_WAIT"
rev=$(serving_revision)
count_logs() {  # count_logs SUBSTRING: number of matching entries since t0 (the lines themselves are never printed)
  gc logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$RUN_SERVICE\" AND resource.labels.revision_name=\"$rev\" AND timestamp>=\"$t0\" AND textPayload:\"$1\"" \
    --limit 20 --format='value(timestamp)' | grep -c . || true
}
fail_n=$(count_logs "[email] failed to send to $TEST_TO")
nocfg_n=$(count_logs "SMTP not configured")
hook_n=$(count_logs "[auth] password reset email failed")
log "test: log lines since $t0 on $rev: smtp-failure=$fail_n  smtp-not-configured=$nocfg_n  hook-failure=$hook_n"
if [[ "$fail_n" == 0 && "$nocfg_n" == 0 && "$hook_n" == 0 && "$code" == 202 ]]; then
  log "test: NO SMTP ERROR logged for this request. The backend logs nothing on success, so this is not proof"
  log "      of delivery: check $TEST_TO's inbox (and spam) for 'Reset your PolarBear password'."
else
  log "test: SMTP FAILED or is not configured. Read the lines yourself (they can contain a reset token, so they are not printed here):"
  log "      gcloud logging read 'resource.labels.revision_name=\"$rev\" AND textPayload:\"[email]\"' --project $PROJECT --limit 5"
  exit 1
fi
finish
