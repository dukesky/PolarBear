#!/usr/bin/env bash
# /opt/polarbear/datastore-secrets.sh: VM-side half of secret rotation and fresh-VM rebuild.
# Installed and driven by infrastructure/gcp/35-rotate-datastore-secrets.sh. The runbook uses
# `render` to rebuild compose.yml on a fresh VM. Runs as root.
#
# SECRET HANDLING (the hard rule): new values arrive on STDIN only, never as arguments.
# Old and current values are read from files into shell/python variables. Nothing here
# prints, logs or passes a secret value on a command line. Output is step names, counts
# and PASS/FAIL. No `set -x`, ever.
#
# Subcommands:
#   preflight            read-only checks: containers, both keys present once, no leftover
#                        backup, Postgres will not log the ALTER statement
#   apply                stdin: line 1 new Postgres password, line 2 new Meili master key (64 hex each).
#                        a. compose.yml -> compose.yml.pre-rotation (root:root 0600)
#                        b. replace ONLY those two values in compose.yml (all other bytes kept)
#                        c. ALTER USER polarbear WITH PASSWORD (SQL on stdin)
#                        d. docker compose up -d   e. wait until both are healthy on the new values
#   restore              put the pre-rotation state back: compose.yml from the backup, ALTER USER
#                        to the old password, docker compose up -d, wait. Removes the backup only
#                        if all of that worked. With no backup present, there is nothing to do.
#   prove-old-dead       Meilisearch must reject the OLD key and accept the NEW one. Postgres over
#                        TCP (scram, via the container's own IP, not trusted 127.0.0.1) must reject
#                        the OLD password and accept the NEW one.
#   count-in-stdin       counts how often the old and the new values appear in stdin (counts only)
#   finish               shred the backup (after a successful rotation)
#   render TEMPLATE      fresh VM: stdin lines as for apply; writes compose.yml from TEMPLATE
#                        (refuses to overwrite an existing compose.yml unless FORCE=1)
#   verify-template TEMPLATE   is TEMPLATE, rendered with the live values, byte-identical to compose.yml?
set -euo pipefail
umask 077

DIR=${POLARBEAR_DIR:-/opt/polarbear}
F="$DIR/compose.yml"
B="$DIR/compose.yml.pre-rotation"
PG=${PG_CONTAINER:-polarbear-postgres-1}
MEILI=${MEILI_CONTAINER:-polarbear-meilisearch-1}
PG_USER=${PG_USER:-polarbear}
PG_DB=${PG_DB:-polarbear}
MEILI_URL=${MEILI_URL:-http://127.0.0.1:7700}
WAIT=${HEALTH_WAIT_SECONDS:-180}

say() { printf '[vm %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { say "ERROR: $*"; exit 1; }

# get_value FILE KEY: prints the value of "- KEY=value" to STDOUT for capture by $(...) only.
# Fails unless KEY appears exactly once.
get_value() {
  python3 - "$1" "$2" <<'PY'
import re, sys
m = re.findall(r"^\s*-\s*" + re.escape(sys.argv[2]) + r"=(.*)$", open(sys.argv[1]).read(), re.M)
if len(m) != 1:
    sys.stderr.write("%s: expected exactly one %s line, found %d\n" % (sys.argv[1], sys.argv[2], len(m))); sys.exit(1)
sys.stdout.write(m[0])
PY
}

read_new_values() {  # sets NEW_PG and NEW_MEILI from stdin, validated
  IFS= read -r NEW_PG || true
  IFS= read -r NEW_MEILI || true
  [[ "$NEW_PG" =~ ^[0-9a-f]{64}$ ]] || die "line 1 of stdin is not 64 lowercase hex characters"
  [[ "$NEW_MEILI" =~ ^[0-9a-f]{64}$ ]] || die "line 2 of stdin is not 64 lowercase hex characters"
  [[ "$NEW_PG" != "$NEW_MEILI" ]] || die "the two new values must differ"
}

# write_with_values SRC DEST PG_VALUE MEILI_VALUE: copies SRC to DEST with only the two
# values replaced. The values go to python on stdin. Output is root:root 0600, via an atomic rename.
write_with_values() {
  local src=$1 dest=$2 tmp
  tmp=$(mktemp "$DIR/.compose.XXXXXX")
  printf '%s\n%s\n' "$3" "$4" | python3 -c '
import re, sys
src, out = sys.argv[1], sys.argv[2]
pg, meili = sys.stdin.read().split("\n")[:2]
text = open(src).read()
for key, val, ph in (("POSTGRES_PASSWORD", pg, "__POSTGRES_PASSWORD__"), ("MEILI_MASTER_KEY", meili, "__MEILI_MASTER_KEY__")):
    pat = re.compile(r"^(\s*-\s*" + key + r"=)(.*)$", re.M)
    if len(pat.findall(text)) != 1:
        sys.exit("expected exactly one %s line in %s" % (key, src))
    text = pat.sub(lambda m: m.group(1) + val, text)
    if ph in text:
        sys.exit("placeholder %s still present" % ph)
open(out, "w").write(text)
' "$src" "$tmp" || { rm -f "$tmp"; return 1; }
  chown root:root "$tmp"; chmod 600 "$tmp"
  mv -f "$tmp" "$dest"
}

alter_pg_password() {  # alter_pg_password VALUE: SQL on stdin. The statement is kept out of the server log.
  # psql's own error output can quote the failing statement ("LINE 3: ALTER USER ..."),
  # so all of it is discarded and only a generic message is printed.
  if ! printf "SET log_min_error_statement = panic;\nSET log_statement = 'none';\nALTER USER %s WITH PASSWORD '%s';\n" "$PG_USER" "$1" |
       docker exec -i "$PG" psql -q -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 >/dev/null 2>&1; then
    say "ALTER USER failed (psql output suppressed because it could quote the statement)"; return 1
  fi
}

meili_code() {  # meili_code KEY PATH: HTTP status of an authenticated GET. The key goes on stdin to curl.
  printf 'header = "Authorization: Bearer %s"\n' "$1" |
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 -K - "$MEILI_URL$2" || true
}

pg_tcp_login() {  # pg_tcp_login PASSWORD: 0 if Postgres accepts it over TCP with scram-sha-256
  # The container's own IP, not 127.0.0.1, which pg_hba trusts without a password.
  # PGPASSWORD reaches psql through docker exec's environment (-e NAME with no value), never argv.
  PGPASSWORD="$1" docker exec -e PGPASSWORD "$PG" sh -c \
    'psql -h "$(hostname -i | cut -d" " -f1)" -U "$0" -d "$1" -Atc "select 1" >/dev/null 2>&1' "$PG_USER" "$PG_DB"
}

compose_up_and_wait() {  # compose_up_and_wait MEILI_KEY
  (cd "$DIR" && docker compose up -d) >/dev/null 2>&1 || { say "docker compose up -d failed"; return 1; }
  local deadline=$(( $(date +%s) + WAIT ))
  while (( $(date +%s) < deadline )); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$PG" "$MEILI" 2>/dev/null | sort -u)" == true ]] &&
       docker exec "$PG" pg_isready -q -U "$PG_USER" -d "$PG_DB" &&
       [[ "$(meili_code "$1" /keys)" == 200 ]]; then
      say "both containers running; Postgres ready; Meilisearch accepts the expected master key"
      return 0
    fi
    sleep 3
  done
  say "containers not healthy after ${WAIT}s"; return 1
}

cmd=${1:-}
case "$cmd" in
  preflight)
    rc=0
    for c in "$PG" "$MEILI"; do
      if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == true ]]; then say "container $c running"
      else say "container $c NOT running"; rc=1; fi
    done
    for k in MEILI_MASTER_KEY POSTGRES_PASSWORD; do
      if get_value "$F" "$k" >/dev/null; then say "$k present exactly once in $F"; else rc=1; fi
    done
    if [[ -e "$B" ]]; then say "a backup $B already exists (a previous rotation did not finish); inspect before rotating"; rc=1
    else say "no leftover $B"; fi
    ls_=$(docker exec "$PG" psql -U "$PG_USER" -d "$PG_DB" -Atc "show log_statement" 2>/dev/null || echo unknown)
    if [[ "$ls_" == none ]]; then say "Postgres log_statement=none"; else say "Postgres log_statement=$ls_ (must be none)"; rc=1; fi
    exit "$rc" ;;

  apply)
    read_new_values
    [[ ! -e "$B" ]] || die "$B already exists; refusing to overwrite the only copy of the old values"
    cp -p "$F" "$B"; chown root:root "$B"; chmod 600 "$B"
    say "a. backup written: $B (root:root 0600)"
    write_with_values "$F" "$F" "$NEW_PG" "$NEW_MEILI"
    say "b. compose.yml: only MEILI_MASTER_KEY and POSTGRES_PASSWORD replaced ($(stat -c '%U:%G %a' "$F"))"
    alter_pg_password "$NEW_PG"
    say "c. ALTER USER $PG_USER done (downtime starts)"
    compose_up_and_wait "$NEW_MEILI"
    say "d/e. docker compose up -d done and healthy on the new values"
    ;;

  restore)
    if [[ ! -e "$B" ]]; then say "no $B: nothing on the VM was changed, nothing to restore"; exit 0; fi
    OLD_PG=$(get_value "$B" POSTGRES_PASSWORD); OLD_MEILI=$(get_value "$B" MEILI_MASTER_KEY)
    rc=0
    cp -p "$B" "$F" && chown root:root "$F" && chmod 600 "$F" && say "compose.yml restored from backup" || { say "compose.yml restore FAILED"; rc=1; }
    alter_pg_password "$OLD_PG" && say "ALTER USER back to the old password done" || { say "ALTER USER back FAILED"; rc=1; }
    compose_up_and_wait "$OLD_MEILI" || rc=1
    if [[ "$rc" == 0 ]]; then shred -u "$B" && say "restore complete; backup shredded"
    else say "restore INCOMPLETE; backup kept at $B for a manual finish"; fi
    exit "$rc" ;;

  prove-old-dead)
    [[ -e "$B" ]] || die "no $B: the old values are not available to test"
    OLD_PG=$(get_value "$B" POSTGRES_PASSWORD); OLD_MEILI=$(get_value "$B" MEILI_MASTER_KEY)
    CUR_PG=$(get_value "$F" POSTGRES_PASSWORD); CUR_MEILI=$(get_value "$F" MEILI_MASTER_KEY)
    rc=0
    c=$(meili_code "$CUR_MEILI" /keys); if [[ "$c" == 200 ]]; then say "PASS Meilisearch accepts the NEW master key (200)"; else say "FAIL Meilisearch with the NEW key -> $c"; rc=1; fi
    c=$(meili_code "$OLD_MEILI" /keys); if [[ "$c" == 401 || "$c" == 403 ]]; then say "PASS Meilisearch rejects the OLD master key ($c)"; else say "FAIL Meilisearch with the OLD key -> $c"; rc=1; fi
    if pg_tcp_login "$CUR_PG"; then say "PASS Postgres (TCP, scram) accepts the NEW password"; else say "FAIL Postgres rejects the NEW password over TCP; the test is not valid"; rc=1; fi
    if pg_tcp_login "$OLD_PG"; then say "FAIL Postgres (TCP, scram) STILL ACCEPTS THE OLD PASSWORD"; rc=1; else say "PASS Postgres (TCP, scram) rejects the OLD password"; fi
    exit "$rc" ;;

  count-in-stdin)
    [[ -e "$B" ]] || die "no $B: the old values are not available"
    OLD_PG=$(get_value "$B" POSTGRES_PASSWORD); OLD_MEILI=$(get_value "$B" MEILI_MASTER_KEY)
    CUR_PG=$(get_value "$F" POSTGRES_PASSWORD); CUR_MEILI=$(get_value "$F" MEILI_MASTER_KEY)
    printf '%s\n%s\n%s\n%s\n' "$OLD_PG" "$OLD_MEILI" "$CUR_PG" "$CUR_MEILI" > "$DIR/.needles.$$"
    # stdin is the text to search. The needles come from a 0600 file, never argv.
    python3 -c '
import sys
needles = open(sys.argv[1]).read().split("\n")[:4]
text = sys.stdin.read()
for label, n in zip(("old postgres password", "old meili key", "new postgres password", "new meili key"), needles):
    print("occurrences of %-22s %d" % (label + ":", text.count(n)))
' "$DIR/.needles.$$"; rc=$?
    shred -u "$DIR/.needles.$$"; exit "$rc" ;;

  finish)
    if [[ -e "$B" ]]; then shred -u "$B" && say "backup $B shredded"; else say "no backup to shred"; fi ;;

  render)
    T=${2:?usage: render TEMPLATE}
    [[ ! -e "$F" || "${FORCE:-0}" == 1 ]] || die "$F exists; refusing to overwrite (FORCE=1 to override)"
    read_new_values
    mkdir -p "$DIR"
    write_with_values "$T" "$F" "$NEW_PG" "$NEW_MEILI"
    say "rendered $F from $T ($(stat -c '%U:%G %a' "$F"))" ;;

  verify-template)
    T=${2:?usage: verify-template TEMPLATE}
    tmp=$(mktemp "$DIR/.verify.XXXXXX")
    write_with_values "$T" "$tmp" "$(get_value "$F" POSTGRES_PASSWORD)" "$(get_value "$F" MEILI_MASTER_KEY)"
    if cmp -s "$tmp" "$F"; then say "template MATCHES the live compose.yml byte for byte"; rc=0
    else say "template DIFFERS from the live compose.yml (beyond the two secret values)"; rc=1; fi
    shred -u "$tmp"; exit "$rc" ;;

  *) echo "usage: $0 preflight|apply|restore|prove-old-dead|count-in-stdin|finish|render TEMPLATE|verify-template TEMPLATE" >&2; exit 2 ;;
esac
