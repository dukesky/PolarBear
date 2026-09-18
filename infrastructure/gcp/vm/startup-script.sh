#!/bin/bash
# PolarBear VM startup-script (instance metadata key `startup-script`). Runs as root on EVERY boot.
# Installed by infrastructure/gcp/35-rotate-datastore-secrets.sh.
#
# It holds NO SECRETS and never writes compose.yml. The Postgres password and
# Meilisearch master key live in Secret Manager and in /opt/polarbear/compose.yml
# (root:root 0600) on the VM's disk. Instance metadata is readable by any process on
# the VM without authentication, so secrets must never be put back here.
#
# On each boot it: installs Docker if missing; refuses to continue if compose.yml
# is missing; re-asserts compose.yml's owner and mode; runs `docker compose up -d`.
set -euo pipefail

DIR=/opt/polarbear
F="$DIR/compose.yml"
log() { echo "polarbear-startup: $*"; logger -t polarbear-startup -- "$*" 2>/dev/null || true; }

if ! command -v docker >/dev/null; then
  log "installing docker"
  curl -fsSL https://get.docker.com | sh
fi

if [[ ! -f "$F" ]]; then
  log "ERROR: $F is missing. This script never generates it, because it holds secrets."
  log "ERROR: Rebuild it from Secret Manager: docs/operations/backup-restore.md, section 'D. Rebuild compose.yml on a Fresh VM'."
  exit 1
fi

chown root:root "$F"
chmod 600 "$F"
cd "$DIR" && docker compose up -d
log "docker compose up -d done"
