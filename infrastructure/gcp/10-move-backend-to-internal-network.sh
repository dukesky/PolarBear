#!/usr/bin/env bash
# 10 — Move the Cloud Run backend onto the VM's internal IP  (brief steps N2, N3, N4)
#
# CHANGES
#   - Cloud Run service polarbear-backend: Direct VPC egress on network
#     `default`, subnet `default` (us-central1), egress private-ranges-only.
#     Direct VPC egress has no standing cost, unlike a Serverless VPC Access connector.
#   - The host part of DATABASE_URL and MEILI_HOST, from the VM's external IP
#     to its reserved internal IP (10.138.0.2). Nothing else in either value
#     changes, and no other env var is touched.
#   All of it is one `gcloud run services update`, so one new revision. Cloud Run
#   rolls it out with no downtime.
#
# VERIFIES
#   Before: the internal IP is reserved and IN_USE by the VM, the us-central1
#   subnet range is what we expect, and a firewall rule already admits that
#   range to the VM on tcp:5432 and tcp:7700.
#   After: per-variable SHA-256 of every env var, before vs after. Only
#   DATABASE_URL and MEILI_HOST may differ, and no variable may appear or
#   disappear. Then the N4 production checks (lib/verify-production.sh).
#
# ROLLS BACK
#   Recovery is armed just before the update. From then on ANY exit short of
#   verified success rolls back: a failed check, a crashed describe/verify
#   call, a set -e abort, Ctrl-C. The rollback routes 100% of traffic back to
#   the revision that was serving when the script started, reads it back,
#   re-runs the checks, and ends with a banner saying what is and is not
#   restored, plus the manual command if the rollback itself failed. The script
#   then exits non-zero.
#
# SAFE TO RE-RUN: if the service is already on the internal network with both
# hosts repointed, it skips the update and only re-runs the checks.
# Values of env vars are never printed, logged or written outside a 0600 temp
# dir that is deleted on exit.
# OUTSIDE THIS SCRIPT'S CONTROL: if gcloud itself rejects the update, its own
# error message could in principle echo part of an argument or flags-file value
# to stderr. The script cannot redact gcloud's output.
#
# Usage:  DRY_RUN=1 ./10-move-backend-to-internal-network.sh    # show the plan, change nothing
#         ./10-move-backend-to-internal-network.sh
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/verify-production.sh
source "$HERE/lib/verify-production.sh"

require gcloud python3 curl
banner "10: move $RUN_SERVICE onto $VPC_NETWORK/$RUN_SUBNET -> $VM_INTERNAL_IP"

TMP=$(mktemp -d)
add_cleanup "$TMP"   # removed by the EXIT handler in lib/common.sh, on every exit path

# ---------------------------------------------------------------- preflight
log "preflight: internal address $VM_INTERNAL_ADDRESS_NAME"
addr=$(gc compute addresses describe "$VM_INTERNAL_ADDRESS_NAME" --region "$REGION" \
         --format='value(address,addressType,status)') ||
  die "static internal address $VM_INTERNAL_ADDRESS_NAME not found in $REGION — reserve it first (brief step N1)"
read -r a_ip a_type a_status <<< "$addr"
[[ "$a_ip" == "$VM_INTERNAL_IP" && "$a_type" == INTERNAL && "$a_status" == IN_USE ]] ||
  die "address $VM_INTERNAL_ADDRESS_NAME is '$addr', want '$VM_INTERNAL_IP INTERNAL IN_USE'"
vm_ip=$(gc compute instances describe "$VM" --zone "$ZONE" --format='value(networkInterfaces[0].networkIP)')
[[ "$vm_ip" == "$VM_INTERNAL_IP" ]] || die "VM internal IP is $vm_ip, expected $VM_INTERNAL_IP"
log "preflight: [OK] $VM_INTERNAL_IP is reserved, IN_USE, and is the VM's internal IP"

range=$(gc compute networks subnets describe "$RUN_SUBNET" --region "$RUN_REGION" --format='value(ipCidrRange)')
[[ "$range" == "$RUN_SUBNET_RANGE" ]] ||
  die "subnet $RUN_SUBNET in $RUN_REGION is $range, script expects $RUN_SUBNET_RANGE (set RUN_SUBNET_RANGE if that is right)"
log "preflight: [OK] $RUN_REGION subnet $RUN_SUBNET = $range"

gc compute instances describe "$VM" --zone "$ZONE" --format=json > "$TMP/vm.json"
gc compute firewall-rules list --format=json > "$TMP/fw.json"
python3 - "$TMP/vm.json" "$TMP/fw.json" "$VPC_NETWORK" "$RUN_SUBNET_RANGE" <<'PY' || die "no firewall rule admits $RUN_SUBNET_RANGE to the VM on both 5432 and 7700; add a narrow one before running this"
import ipaddress, json, sys
vm, rules, net, rng = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3], ipaddress.ip_network(sys.argv[4])
tags = set(vm.get("tags", {}).get("items", []))
def admits(rule, port):
    if rule.get("direction") != "INGRESS" or rule.get("disabled") or not rule["network"].endswith("/" + net):
        return False
    if rule.get("targetTags") and not tags & set(rule["targetTags"]):
        return False
    if rule.get("targetServiceAccounts"):
        return False
    if not any(rng.subnet_of(ipaddress.ip_network(s)) for s in rule.get("sourceRanges", [])):
        return False
    for a in rule.get("allowed", []):
        if a["IPProtocol"] in ("tcp", "all"):
            if "ports" not in a:
                return True
            for p in a["ports"]:
                lo, _, hi = p.partition("-")
                if int(lo) <= port <= int(hi or lo):
                    return True
    return False
ok = True
for port in (5432, 7700):
    names = [r["name"] for r in rules if admits(r, port)]
    print(f"preflight: tcp:{port} from {rng} admitted by: {', '.join(names) or 'NOTHING'}", file=sys.stderr)
    ok &= bool(names)
sys.exit(0 if ok else 1)
PY
log "preflight: [OK] firewall admits $RUN_SUBNET_RANGE to the VM on 5432 and 7700"

# ---------------------------------------------------------------- env helpers
describe_service() { gc run services describe "$RUN_SERVICE" --region "$RUN_REGION" --format=json; }

# NAME SHA256 per env var, sorted. A secret reference is hashed as its JSON.
env_hashes() {
  python3 - "$1" <<'PY'
import hashlib, json, sys
env = json.load(open(sys.argv[1]))["spec"]["template"]["spec"]["containers"][0].get("env", [])
for e in sorted(env, key=lambda e: e["name"]):
    v = e["value"] if "value" in e else json.dumps(e.get("valueFrom"), sort_keys=True)
    print(e["name"], hashlib.sha256(v.encode()).hexdigest())
PY
}

# Prints the network settings now: "<network-interfaces JSON or -> <egress or ->". Never a value.
# (Hosts come from lib/common.sh:backend_datastore_hosts, which handles literal AND secret-ref values.)
network_now() {
  python3 - "$1" <<'PY'
import json, sys
ann = json.load(open(sys.argv[1]))["spec"]["template"]["metadata"].get("annotations", {})
print(ann.get("run.googleapis.com/network-interfaces", "") or "-", ann.get("run.googleapis.com/vpc-access-egress", "") or "-")
PY
}

# Writes a gcloud --flags-file repointing the LITERAL vars named in $3 ("DATABASE_URL MEILI_HOST").
# Only the host changes. (Callers never pass a secret-ref var: the plan refuses that case.)
write_flags_file() {
  python3 - "$1" "$VM_INTERNAL_IP" "$VPC_NETWORK" "$RUN_SUBNET" "$3" > "$2" <<'PY'
import json, sys, urllib.parse as up
svc, ip, net, subnet, names = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5].split()
env = {e["name"]: e["value"] for e in svc["spec"]["template"]["spec"]["containers"][0]["env"] if "value" in e}
def repoint(v):
    p = up.urlsplit(v)
    userinfo, at, hostport = p.netloc.rpartition("@")
    port = f":{p.port}" if p.port else ""
    return up.urlunsplit(p._replace(netloc=f"{userinfo}{at}{ip}{port}"))
new = {k: repoint(env[k]) for k in names}
for k in new:
    assert up.urlsplit(new[k]).hostname == ip and up.urlsplit(new[k]).port == up.urlsplit(env[k]).port
flags = {"--network": net, "--subnet": subnet, "--vpc-egress": "private-ranges-only"}
if new: flags["--update-env-vars"] = new
print(json.dumps(flags))
PY
  chmod 600 "$2"
}

env_kind_10() {  # literal | secret | absent (never a value)
  python3 -c 'import json,sys; e={x["name"]:x for x in json.load(open(sys.argv[1]))["spec"]["template"]["spec"]["containers"][0].get("env",[])}.get(sys.argv[2]); print("absent" if e is None else ("literal" if "value" in e else "secret"))' "$1" "$2"
}

# ---------------------------------------------------------------- before
START_REV=$(serving_revision)
[[ -n "$START_REV" ]] || die "could not determine the serving revision"
log "before: serving revision = $START_REV (rollback target)"

describe_service > "$TMP/before.json"
env_hashes "$TMP/before.json" > "$TMP/before.hashes"
log "before: env var names and SHA-256 (first 16 hex shown):"
awk '{printf "    %-20s %s\n", $1, substr($2,1,16)}' "$TMP/before.hashes" >&2

hosts=$(backend_datastore_hosts) || die "cannot determine which hosts the backend uses (see the error above)"
read -r db_host meili_host <<< "$hosts"
read -r cur_net cur_egress <<< "$(network_now "$TMP/before.json")"
need_db=0; need_meili=0; to_repoint=""
if [[ "$db_host" != "$VM_INTERNAL_IP" ]]; then need_db=1; to_repoint="DATABASE_URL"; fi
if [[ "$meili_host" != "$VM_INTERNAL_IP" ]]; then need_meili=1; to_repoint="${to_repoint:+$to_repoint }MEILI_HOST"; fi
for v in $to_repoint; do
  [[ "$(env_kind_10 "$TMP/before.json" "$v")" == literal ]] ||
    die "$v needs repointing but is a secret reference; add a secret version with the new host and re-pin it (runbook section E). This script only repoints literal values"
done
log "before: DATABASE_URL host=$db_host ($(env_kind_10 "$TMP/before.json" DATABASE_URL))  MEILI_HOST host=$meili_host ($(env_kind_10 "$TMP/before.json" MEILI_HOST))"
log "before: network-interfaces=$cur_net  vpc-access-egress=$cur_egress"

net_ok=0
if [[ "$cur_egress" == private-ranges-only ]] &&
   python3 -c 'import json,sys; n=json.loads(sys.argv[1]); sys.exit(0 if n and n[0].get("network")==sys.argv[2] and n[0].get("subnetwork")==sys.argv[3] else 1)' \
     "$cur_net" "$VPC_NETWORK" "$RUN_SUBNET" 2>/dev/null; then
  net_ok=1
fi

# ---------------------------------------------------------------- rollback
# Recovery for this script. Runs from the EXIT handler (lib/common.sh) on ANY exit
# while armed, including a set -e abort, a crashing verify step or Ctrl-C, with set +e.
# Best effort: it tries everything, then says exactly what is and is not restored.
rollback() {
  local problems="" now
  log "ROLLBACK: routing 100% of traffic back to $START_REV"
  if run gc run services update-traffic "$RUN_SERVICE" --region "$RUN_REGION" --to-revisions "$START_REV=100"; then
    now=$(serving_revision 2>/dev/null)
    if [[ "$now" == "$START_REV" ]]; then log "ROLLBACK: [OK] $START_REV serves 100% of traffic"
    else problems="$problems|serving revision reads back as '${now:-unknown}', not $START_REV"; fi
  else
    problems="$problems|gcloud run services update-traffic ... --to-revisions $START_REV=100 FAILED"
  fi
  if [[ -z "$problems" ]]; then
    log "ROLLBACK: re-checking production on $START_REV"
    verify_production "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ||
      problems="$problems|production checks still FAIL on $START_REV — the cause may not be this change"
  fi
  if [[ -z "$problems" ]]; then
    alarm "ROLLED BACK — production is on $START_REV again and passes the checks" \
      "Restored:     100% of traffic on $START_REV (the revision serving before this script)." \
      "NOT restored: the service TEMPLATE still holds the new network + env settings, and" \
      "              traffic is PINNED to $START_REV, so a plain deploy would not take traffic." \
      "To finish:    fix the cause and re-run this script, or restore the old settings and run" \
      "              gcloud run services update-traffic $RUN_SERVICE --to-latest --region $RUN_REGION --project $PROJECT"
  else
    local IFS='|'
    # shellcheck disable=SC2086
    alarm "ROLLBACK INCOMPLETE — production may still be on the NEW network/env config" \
      ${problems#|} \
      "Do this by hand now:" \
      "  gcloud run services update-traffic $RUN_SERVICE --region $RUN_REGION --project $PROJECT --to-revisions $START_REV=100" \
      "  gcloud run services describe $RUN_SERVICE --region $RUN_REGION --project $PROJECT --format='value(status.traffic)'" \
      "Then re-check: bash -c 'source $HERE/lib/common.sh; source $HERE/lib/verify-production.sh; verify_production && finish'"
  fi
}

# ---------------------------------------------------------------- change
if [[ "$need_db" == 0 && "$need_meili" == 0 && "$net_ok" == 1 ]]; then
  log "change: already on $VPC_NETWORK/$RUN_SUBNET with both hosts at $VM_INTERNAL_IP — nothing to update"
  CHANGED=0
else
  log "change: repoint [${to_repoint:-none}] to $VM_INTERNAL_IP; network ${cur_egress} -> $VPC_NETWORK/$RUN_SUBNET private-ranges-only"
  flags="$TMP/flags.json"
  shown=""; for v in $to_repoint; do shown="${shown:+$shown,}$v=<redacted, host=$VM_INTERNAL_IP>"; done
  display="gcloud run services update $RUN_SERVICE --region $RUN_REGION --project $PROJECT --flags-file=<0600 temp file: --network=$VPC_NETWORK --subnet=$RUN_SUBNET --vpc-egress=private-ranges-only${shown:+ --update-env-vars $shown}>"
  if is_dry_run; then
    run_shown_as "$display" true
  else
    write_flags_file "$TMP/before.json" "$flags" "$to_repoint"
    # From here on, ANY exit that is not the success at the bottom rolls back.
    arm_recovery rollback
    run_shown_as "$display" gc run services update "$RUN_SERVICE" --region "$RUN_REGION" --flags-file "$flags"
    rm -f "$flags"
  fi
  CHANGED=1
fi

if is_dry_run; then
  log "after: (dry run) the env check would require exactly these hashes to change:"
  if [[ "$need_db" == 1 ]]; then log "    DATABASE_URL"; fi
  if [[ "$need_meili" == 1 ]]; then log "    MEILI_HOST"; fi
  log "after: (dry run) running the N4 checks against CURRENT production as a baseline"
  verify_production || log "baseline checks failed — production is unhealthy BEFORE any change"
  log "DRY RUN complete: nothing was changed"
  finish
fi

# ---------------------------------------------------------------- env check
# Every statement below may fail. While recovery is armed, any failure (or a
# plain `exit 1`) runs rollback() through the EXIT handler.
describe_service > "$TMP/after.json"
env_hashes "$TMP/after.json" > "$TMP/after.hashes"
log "after: env var names and SHA-256 (first 16 hex shown):"
awk '{printf "    %-20s %s\n", $1, substr($2,1,16)}' "$TMP/after.hashes" >&2
changed=$(python3 - "$TMP/before.hashes" "$TMP/after.hashes" <<'PY2'
import sys
b = dict(l.split() for l in open(sys.argv[1]) if l.strip())
a = dict(l.split() for l in open(sys.argv[2]) if l.strip())
if set(a) != set(b):
    print("NAMES-DIFFER:added=%s,removed=%s" % (sorted(set(a)-set(b)), sorted(set(b)-set(a)))); sys.exit()
print(" ".join(sorted(k for k in a if a[k] != b[k])) or "none")
PY2
)
expected=""
if [[ "$need_db" == 1 ]]; then expected="DATABASE_URL"; fi
if [[ "$need_meili" == 1 ]]; then expected="${expected:+$expected }MEILI_HOST"; fi
log "after: env vars whose hash changed: $changed  (expected: ${expected:-none})"
if [[ "$changed" != "${expected:-none}" ]]; then
  log "FAIL: unexpected env change"
  exit 1
fi
if [[ "$(backend_datastore_hosts)" != "$VM_INTERNAL_IP $VM_INTERNAL_IP" ]]; then
  log "FAIL: hosts are not $VM_INTERNAL_IP after the update"
  exit 1
fi
log "after: [OK] only the expected variables changed and both hosts are $VM_INTERNAL_IP"

# ---------------------------------------------------------------- N4
new_rev=$(serving_revision)
log "after: serving revision = $new_rev"
if ! verify_production; then
  if [[ "$CHANGED" == 0 ]]; then log "FAIL: checks fail and this run changed nothing, so there is nothing to roll back"; fi
  exit 1
fi
disarm_recovery
log "DONE: $RUN_SERVICE reaches Postgres and Meilisearch at $VM_INTERNAL_IP (revision $new_rev)"
finish
