#!/usr/bin/env bash
# /opt/polarbear/backup.sh — nightly logical backups of PolarBear's datastores.
# Installed on the VM by infrastructure/gcp/40-install-backups.sh; runs as root from cron.
#
# CHANGES
#   Uploads two objects per run:
#     $BACKUP_BUCKET/postgres/polarbear-<UTC ts>.sql.gz   pg_dump of the whole DB, gzipped
#     $BACKUP_BUCKET/meilisearch/<UTC ts>.dump            a Meilisearch dump (every index,
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
STEP=start
WORK=""
DUMP_UID=""

log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STEP" "$*"; }

read_meili_key() {
  MEILI_KEY=$(sed -n -E 's/^[[:space:]]*-?[[:space:]]*"?MEILI_MASTER_KEY[[:space:]]*[=:][[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "$COMPOSE_FILE" | head -n 1)
  [[ -n "$MEILI_KEY" ]]
}

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
  log "would: docker exec $PG_CONTAINER pg_dump -U $PG_USER -d $PG_DB | gzip -9 -> $BACKUP_BUCKET/postgres/polarbear-$TS.sql.gz"
  log "would: POST $MEILI_URL/dumps, poll the task, docker cp $MEILI_CONTAINER:$MEILI_DUMP_DIR/<uid>.dump -> $BACKUP_BUCKET/meilisearch/$TS.dump, delete local + in-container copies"
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
  cloud_log ERROR "polarbear backup $TS FAILED at step=$STEP exit=$rc (see $LOG_FILE on the VM)"
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

# meili METHOD PATH — the Authorization header reaches curl through stdin (-K -),
# so the key is never on a command line, in `ps`, or in the log.
meili() {
  printf 'header = "Authorization: Bearer %s"\n' "$MEILI_KEY" |
    curl -sS --fail-with-body --max-time 60 -K - -X "$1" "$MEILI_URL$2"
}

upload() {  # upload LOCAL_FILE GS_URL — copy, then prove the object is there and the same size
  local src=$1 dst=$2 local_size remote_size
  local_size=$(stat -c %s "$src")
  gsutil -q cp "$src" "$dst"
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
log "backup $TS starting -> $BACKUP_BUCKET"
WORK=$(mktemp -d "$WORK_PARENT/polarbear-backup.XXXXXX")

# ------------------------------------------------------------------ postgres
STEP=postgres-dump
PG_OUT="$WORK/polarbear-$TS.sql.gz"
# Inside the container pg_dump uses the local socket, so no password is involved.
docker exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" --no-password | gzip -9 > "$PG_OUT"
gzip -t "$PG_OUT"
if ! gzip -dc "$PG_OUT" | tail -n 5 | grep -q 'PostgreSQL database dump complete'; then
  log "pg_dump output has no 'dump complete' trailer; the dump is truncated"; false
fi
log "pg_dump ok ($(stat -c %s "$PG_OUT") bytes gzipped)"

STEP=postgres-upload
upload "$PG_OUT" "$BACKUP_BUCKET/postgres/polarbear-$TS.sql.gz"
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
MEILI_OUT="$WORK/$TS.dump"
docker cp "$MEILI_CONTAINER:$MEILI_DUMP_DIR/$DUMP_UID.dump" "$MEILI_OUT" >/dev/null
[[ -s "$MEILI_OUT" ]] || { log "copied dump is empty"; false; }
docker exec "$MEILI_CONTAINER" rm -f "$MEILI_DUMP_DIR/$DUMP_UID.dump"
DUMP_UID=""   # removed; nothing left for cleanup to do in the container
log "dump copied out of the container and removed from it ($(stat -c %s "$MEILI_OUT") bytes)"

STEP=meili-upload
upload "$MEILI_OUT" "$BACKUP_BUCKET/meilisearch/$TS.dump"
rm -f "$MEILI_OUT"

# ------------------------------------------------------------------ done
STEP=done
log "backup $TS OK"
cloud_log INFO "polarbear backup $TS OK"
