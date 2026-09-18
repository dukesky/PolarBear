#!/usr/bin/env bash
# /opt/polarbear/backup.sh — nightly logical backups of PolarBear's datastores.
# Installed on the VM by infrastructure/gcp/40-install-backups.sh; runs as root from cron.
#
# CHANGES
#   Uploads two objects per run. <run id> is the UTC time to the second plus 6 random
#   hex digits, e.g. 20260918T091701Z-3fa9c2, so two runs can never share a name. The
#   upload also refuses to overwrite an existing object:
#     $BACKUP_BUCKET/postgres/polarbear-<run id>.sql.gz   pg_dump of the whole DB, gzipped
#     $BACKUP_BUCKET/meilisearch/<run id>.dump            a Meilisearch dump (every index,
#                                                         settings, and API keys)
#   Leaves nothing behind on disk. The local copies and the dump file inside the
#   Meilisearch container are deleted whether the run succeeds or fails.
#
# VERIFIES
#   gzip integrity plus pg_dump's "dump complete" trailer. Meilisearch task status
#   `succeeded`. Each uploaded object exists with the same byte size as the local file.
#
# FAILS LOUDLY
#   set -euo pipefail. Every step writes a timestamped line to $LOG_FILE (and
#   stdout). Any failure logs "FAILED step=<name> exit=<code>", best-effort
#   writes an ERROR entry to Cloud Logging (log name polarbear-backup), and
#   exits non-zero.
#   No password, master key or connection string is ever printed. The master
#   key is read from compose.yml at runtime and handed to curl on stdin, never
#   on a command line.
#
# Every setting below can be overridden from the environment, e.g. for a test:
#   sudo BACKUP_BUCKET=gs://does-not-exist-xyz /opt/polarbear/backup.sh   # must fail loudly
#
# HELPER SUBCOMMANDS. The restore runbook uses these, so the master key is
# extracted in exactly one place (read_meili_key below):
#   backup.sh meili-request METHOD PATH [BASE_URL]  authenticated Meilisearch call, JSON on stdout
#                                                   (BASE_URL defaults to $MEILI_URL; e.g. http://127.0.0.1:7701)
#   backup.sh meili-key                             prints the master key for a pipe or $(...);
#                                                   refuses when stdout is a terminal
#   DRY_RUN=1 backup.sh                             checks prerequisites, changes nothing
set -Eeuo pipefail
umask 077

BACKUP_BUCKET=${BACKUP_BUCKET:-gs://polarbear-backups-479000}
PG_CONTAINER=${PG_CONTAINER:-polarbear-postgres-1}
PG_USER=${PG_USER:-polarbear}
PG_DB=${PG_DB:-polarbear}
MEILI_CONTAINER=${MEILI_CONTAINER:-polarbear-meilisearch-1}
MEILI_URL=${MEILI_URL:-http://127.0.0.1:7700}
MEILI_DUMP_DIR=${MEILI_DUMP_DIR:-/meili_data/dumps}     # inside the container
COMPOSE_FILE=${COMPOSE_FILE:-/opt/polarbear/compose.yml}
LOG_FILE=${LOG_FILE:-/var/log/polarbear-backup.log}
WORK_PARENT=${WORK_PARENT:-/var/tmp}
LOCK_FILE=${LOCK_FILE:-/var/lock/polarbear-backup.lock}
MEILI_TASK_TIMEOUT=${MEILI_TASK_TIMEOUT:-900}            # seconds
CLOUD_LOG=${CLOUD_LOG:-1}                                # 0 disables the Cloud Logging entry

DRY_RUN=${DRY_RUN:-0}                                    # 1 = check prerequisites, change nothing

TS=$(date -u +%Y%m%dT%H%M%SZ)
RUN_ID="$TS-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
STEP=start
WORK=""
DUMP_UID=""

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STEP" "$*"; }

# THE one place the master key is extracted (backup runs and the runbook's restore
# steps both come through here). Handles `- MEILI_MASTER_KEY=v` and `MEILI_MASTER_KEY: v`,
# quoted or not.
read_meili_key() {
  MEILI_KEY=$(sed -n -E 's/^[[:space:]]*-?[[:space:]]*"?MEILI_MASTER_KEY[[:space:]]*[=:][[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "$COMPOSE_FILE" | head -n 1)
  [[ -n "$MEILI_KEY" ]]
}

# meili METHOD PATH [BASE_URL]: the Authorization header reaches curl through
# stdin (-K -), so the key is never on a command line, in `ps`, or in the log.
meili() {
  printf 'header = "Authorization: Bearer %s"\n' "$MEILI_KEY" |
    curl -sS --fail-with-body --max-time 60 -K - -X "$1" "${3:-$MEILI_URL}$2"
}

case "${1:-}" in
  "") ;;   # a normal backup run, below
  meili-request)
    [[ $# -ge 3 ]] || { echo "usage: $0 meili-request METHOD PATH [BASE_URL]" >&2; exit 2; }
    read_meili_key || { echo "MEILI_MASTER_KEY not found in $COMPOSE_FILE" >&2; exit 1; }
    meili "$2" "$3" "${4:-}"; echo; exit 0 ;;
  meili-key)
    if [[ -t 1 ]]; then
      echo "refusing to print the master key to a terminal; use it in a pipe or \$(...)" >&2; exit 2
    fi
    read_meili_key || { echo "MEILI_MASTER_KEY not found in $COMPOSE_FILE" >&2; exit 1; }
    printf '%s\n' "$MEILI_KEY"; exit 0 ;;
  *) echo "unknown subcommand: $1 (see the header of $0)" >&2; exit 2 ;;
esac

if [[ "$DRY_RUN" == 1 ]]; then
  # Read-only: no dump, no upload, no lock, nothing written to $LOG_FILE.
  STEP=dry-run
  rc=0
  for c in "$PG_CONTAINER" "$MEILI_CONTAINER"; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == true ]]; then log "container $c running"
    else log "container $c NOT running"; rc=1; fi
  done
  if read_meili_key; then log "master key found in $COMPOSE_FILE (not shown)"
  else log "master key NOT found in $COMPOSE_FILE"; rc=1; fi
  for t in gzip gsutil jq curl flock docker; do
    command -v "$t" >/dev/null || { log "missing tool: $t"; rc=1; }
  done
  log "would: docker exec $PG_CONTAINER pg_dump -U $PG_USER -d $PG_DB | gzip -9 -> $BACKUP_BUCKET/postgres/polarbear-$RUN_ID.sql.gz"
  log "would: POST $MEILI_URL/dumps, poll the task, docker cp $MEILI_CONTAINER:$MEILI_DUMP_DIR/<uid>.dump -> $BACKUP_BUCKET/meilisearch/$RUN_ID.dump, delete local + in-container copies"
  log "would: log each step to $LOG_FILE"
  exit "$rc"
fi

# All output, including errors from the tools, goes to the log file and to stdout.
exec > >(tee -a "$LOG_FILE") 2>&1

cloud_log() {  # cloud_log SEVERITY MESSAGE — best effort, never fails the run
  [[ "$CLOUD_LOG" == 1 ]] || return 0
  gcloud logging write polarbear-backup "$2" --severity="$1" --quiet >/dev/null 2>&1 || true
}

on_error() {
  local rc=$?
  trap - ERR
  log "FAILED step=$STEP exit=$rc"
  cloud_log ERROR "polarbear backup $RUN_ID FAILED at step=$STEP exit=$rc (see $LOG_FILE on the VM)"
  exit "$rc"
}
trap on_error ERR

cleanup() {
  if [[ -n "$DUMP_UID" ]]; then
    docker exec "$MEILI_CONTAINER" rm -f "$MEILI_DUMP_DIR/$DUMP_UID.dump" 2>/dev/null || true
  fi
  if [[ -n "$WORK" ]]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

upload() {  # upload LOCAL_FILE GS_URL — copy, then prove the object is there and the same size
  local src=$1 dst=$2 local_size remote_size
  local_size=$(stat -c %s "$src")
  # if-generation-match:0 = only create; never overwrite an existing backup object.
  gsutil -q -h "x-goog-if-generation-match:0" cp "$src" "$dst"
  remote_size=$(gsutil stat "$dst" | awk -F: '/Content-Length/ {gsub(/ /, "", $2); print $2}')
  if [[ "$remote_size" != "$local_size" ]]; then
    log "uploaded size $remote_size != local size $local_size for $dst"
    return 1
  fi
  log "uploaded $dst ($local_size bytes)"
}

# ------------------------------------------------------------------ start
STEP=lock
exec 9> "$LOCK_FILE"
if ! flock -n 9; then log "another backup is still running"; false; fi
log "backup $RUN_ID starting -> $BACKUP_BUCKET"
WORK=$(mktemp -d "$WORK_PARENT/polarbear-backup.XXXXXX")

# ------------------------------------------------------------------ postgres
STEP=postgres-dump
PG_OUT="$WORK/polarbear-$RUN_ID.sql.gz"
# Inside the container pg_dump uses the local socket, so no password is involved.
docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" --no-password | gzip -9 > "$PG_OUT"
gzip -t "$PG_OUT"
if ! gzip -dc "$PG_OUT" | tail -n 5 | grep -q 'PostgreSQL database dump complete'; then
  log "pg_dump output has no 'dump complete' trailer; the dump is truncated"; false
fi
log "pg_dump ok ($(stat -c %s "$PG_OUT") bytes gzipped)"

STEP=postgres-upload
upload "$PG_OUT" "$BACKUP_BUCKET/postgres/polarbear-$RUN_ID.sql.gz"
rm -f "$PG_OUT"

# ------------------------------------------------------------------ meilisearch
STEP=meili-key
if ! read_meili_key; then log "could not read MEILI_MASTER_KEY from $COMPOSE_FILE"; false; fi
log "master key read from $COMPOSE_FILE (not shown)"

STEP=meili-dump-create
task_uid=$(meili POST /dumps | jq -er '.taskUid')
log "dump task $task_uid enqueued"

STEP=meili-dump-wait
deadline=$(( $(date +%s) + MEILI_TASK_TIMEOUT ))
while :; do
  task=$(meili GET "/tasks/$task_uid")
  status=$(jq -r '.status' <<< "$task")
  case "$status" in
    succeeded) break ;;
    failed|canceled)
      log "dump task $task_uid $status: $(jq -c '.error // {}' <<< "$task")"; false ;;
  esac
  if (( $(date +%s) > deadline )); then
    log "dump task $task_uid still '$status' after ${MEILI_TASK_TIMEOUT}s"; false
  fi
  sleep 2
done
DUMP_UID=$(jq -er '.details.dumpUid' <<< "$task")
log "dump task $task_uid succeeded, dumpUid=$DUMP_UID"

STEP=meili-dump-copy
MEILI_OUT="$WORK/$RUN_ID.dump"
docker cp "$MEILI_CONTAINER:$MEILI_DUMP_DIR/$DUMP_UID.dump" "$MEILI_OUT" >/dev/null
[[ -s "$MEILI_OUT" ]] || { log "copied dump is empty"; false; }
docker exec "$MEILI_CONTAINER" rm -f "$MEILI_DUMP_DIR/$DUMP_UID.dump"
DUMP_UID=""   # removed; nothing left for cleanup to do in the container
log "dump copied out of the container and removed from it ($(stat -c %s "$MEILI_OUT") bytes)"

STEP=meili-upload
upload "$MEILI_OUT" "$BACKUP_BUCKET/meilisearch/$RUN_ID.dump"
rm -f "$MEILI_OUT"

# ------------------------------------------------------------------ done
STEP=done
log "backup $RUN_ID OK"
cloud_log INFO "polarbear backup $RUN_ID OK"
