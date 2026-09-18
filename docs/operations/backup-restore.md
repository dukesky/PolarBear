# Backups and Restore — Hosted PolarBear

This page covers what the hosted service backs up, where the backups live,
how long they are kept, and how to get data back. It is written to be
followed step by step, half awake. Read each step's **Check** line before you
move to the next one.

Everything below runs from a Mac with `gcloud` logged in to the project,
unless the step says **on the VM**.

---

## The Setup in One Screen

All merchant data lives on one e2-micro VM, `polarbear-services`
(zone `us-west1-b`, project `polarbear-dev-479000`). It runs two containers
from `/opt/polarbear/compose.yml`:

| Container | Holds | If it is lost |
|---|---|---|
| `polarbear-postgres-1` | Accounts, tenants, API keys, search analytics | Nobody can log in; widgets stop working |
| `polarbear-meilisearch-1` | Every merchant catalog, one index per tenant (`products_<tenant_id>`) | Every catalog is gone; merchants would have to re-upload |

The Cloud Run backend (`polarbear-backend`, `us-central1`) reaches both over
the VM's **internal** IP `10.138.0.2`, which is reserved as
`polarbear-services-internal`. The VM's external IP is ephemeral and nothing
depends on it.

### Where the secrets live

This page never contains a password or key. When a step needs one, it reads
it from where it already lives:

- **Secret Manager** (project `polarbear-dev-479000`) is the source of truth:

  | Secret | Holds | Used by |
  |---|---|---|
  | `polarbear-postgres-password` | the `polarbear` database user's password | compose.yml on the VM; rebuilds |
  | `polarbear-meili-master-key` | the Meilisearch master key | compose.yml on the VM; Cloud Run `MEILI_MASTER_KEY` |
  | `polarbear-database-url` | the backend's full `postgresql+asyncpg://…@10.138.0.2:5432/polarbear` URL | Cloud Run `DATABASE_URL` |
  | `polarbear-smtp-password` | the Gmail app password (created by the owner) | Cloud Run `SMTP_PASSWORD` |

  Cloud Run references **pinned version numbers**, never `latest`, so a new version
  only takes effect when you re-pin it. The versions in service carry the alias
  **`in-use`** (set by script 35).
- **On the VM:** `/opt/polarbear/compose.yml`, `root:root 0600`. Only root can read it,
  so use `sudo` for `docker compose` commands.
- **Not in the startup-script any more.** Since script 35 the VM's `startup-script`
  metadata is `infrastructure/gcp/vm/startup-script.sh`. It holds no secrets and **never
  writes compose.yml**. It installs Docker if missing, re-asserts compose.yml's
  owner and mode, and runs `docker compose up -d`. If compose.yml is missing it
  stops and points here (section D). Never put a secret back into instance metadata:
  any process on the VM can read metadata without authentication.

To see which secret and version each backend variable uses, **without printing any
value**:

```bash
gcloud run services describe polarbear-backend --region us-central1 --project polarbear-dev-479000 --format=json |
  python3 -c 'import json,sys
for e in json.load(sys.stdin)["spec"]["template"]["spec"]["containers"][0].get("env",[]):
    r = e.get("valueFrom",{}).get("secretKeyRef")
    print(e["name"], "->", "secret %s version %s" % (r["name"], r["key"]) if r else "(literal, value not shown)")'
```

**Never print a secret to look at it.** Don't `cat` compose.yml, don't
`describe` a service's env as YAML, don't `echo` a variable holding a secret.
To check whether two values match, compare hashes. Values move between machines
only through pipes, never on a command line.

---

## What Is Backed Up

| What | How | Where | Kept for |
|---|---|---|---|
| The whole VM disk (OS, Docker, both databases' files, compose.yml) | Snapshot schedule `polarbear-daily-snapshots`, daily, starting 10:00 UTC | Compute Engine snapshots, stored in `us-west1` | 7 days |
| Postgres, logical dump | `/opt/polarbear/backup.sh`, root cron at **09:17 UTC** | `gs://polarbear-backups-479000/postgres/polarbear-<run id>.sql.gz` | 30 days, then 7 more days recoverable (soft delete) |
| Meilisearch, native dump (all indexes, settings, API keys) | same script, same run | `gs://polarbear-backups-479000/meilisearch/<run id>.dump` | 30 days, then 7 more days recoverable (soft delete) |
| FAISS vector files | Object versioning on the bucket | `gs://polarbear-indexes-479000/tenants/<tenant_id>/` | Up to 3 old versions per file, none older than 30 days |
| One-off, before the 2026-09-18 network change | Manual snapshot | `polarbear-services-pre-network-2026-09-18` | Until someone deletes it |

The backup bucket is private: uniform bucket-level access is on and public
access prevention is enforced. **Treat both dumps as sensitive.** The
Postgres dump holds password hashes and API keys. The Meilisearch dump holds
Meilisearch's own API keys.

Not backed up: the Cloud Run services' configuration, including env vars.
Every old revision keeps its own copy, so
`gcloud run revisions list --service polarbear-backend --region us-central1`
followed by `gcloud run revisions describe <rev> --region us-central1` recovers
it. Container images can be rebuilt from git with `cloudbuild.yaml`.

A `<run id>` looks like `20260918T091701Z-3fa9c2`: the UTC start time plus 6
random hex digits, so two runs never share a name. Both objects from one run
share the same run id.

The backup bucket also keeps **deleted or overwritten objects for 7 days**
(soft delete). If backups were deleted by mistake, or by a compromised VM,
list and bring them back:

```bash
gcloud storage ls --soft-deleted -l gs://polarbear-backups-479000/postgres/
gcloud storage restore "gs://polarbear-backups-479000/postgres/polarbear-<run id>.sql.gz#<generation>"
```

---

## Is the Backup Working?

```bash
# The newest objects. Expect one of each from last night's run.
gcloud storage ls -l gs://polarbear-backups-479000/postgres/    | tail -n 3
gcloud storage ls -l gs://polarbear-backups-479000/meilisearch/ | tail -n 3

# The newest snapshots
gcloud compute snapshots list --project polarbear-dev-479000 \
  --filter="sourceDisk~polarbear-services" --sort-by=~creationTimestamp --limit 3
```

The script's own log is **on the VM**:

```bash
gcloud compute ssh polarbear-services --zone us-west1-b --project polarbear-dev-479000
sudo tail -n 30 /var/log/polarbear-backup.log
```

A good run ends with `[done] backup <run id> OK`. A failed run has a line
like `FAILED step=postgres-upload exit=1`, and the lines above it show what
went wrong. Every run also writes one entry to Cloud Logging under the log
name `polarbear-backup`: severity INFO when it works, ERROR when it fails.
Find failures with:

```bash
gcloud logging read 'logName:"polarbear-backup" AND severity>=ERROR' \
  --project polarbear-dev-479000 --freshness=7d --limit 5
```

To run a backup by hand **on the VM**: `sudo /opt/polarbear/backup.sh`. It
exits 0 only if both objects were uploaded and their sizes checked.

---

## Before Any Restore

1. **Decide what you are restoring.** Is one database wrong (use A or B), or
   is the VM broken or gone (use C)?
2. **Take a snapshot of the disk as it is now**, even if it is broken, so the
   restore itself can be undone:
   ```bash
   gcloud compute snapshots create polarbear-services-before-restore-$(date -u +%Y%m%d-%H%M) \
     --source-disk polarbear-services --source-disk-zone us-west1-b \
     --storage-location us-west1 --project polarbear-dev-479000
   ```
   **Check:** the command ends with `done`.
3. Pick the backup. List objects (above) and choose the newest timestamp
   from before the problem started.

---

## A. Restore Postgres from a Dump

Restoring Postgres happens in two stages. First load the dump into a
**new** database, `polarbear_restore`, and check it. Then swap it in for
`polarbear`. Until the swap, production is untouched.

**On the VM** (`gcloud compute ssh polarbear-services --zone us-west1-b --project polarbear-dev-479000`):

```bash
RUN=20260918T091701Z-3fa9c2      # <- the backup you chose (between polarbear- and .sql.gz)
sudo gsutil cp gs://polarbear-backups-479000/postgres/polarbear-$RUN.sql.gz /var/tmp/
gzip -t /var/tmp/polarbear-$RUN.sql.gz && echo "archive OK"
```
**Check:** `archive OK`.

Load it into a scratch database:

```bash
sudo docker exec polarbear-postgres-1 dropdb -U polarbear --if-exists polarbear_restore
sudo docker exec polarbear-postgres-1 createdb -U polarbear polarbear_restore
gunzip -c /var/tmp/polarbear-$RUN.sql.gz | \
  sudo docker exec -i polarbear-postgres-1 psql -q -U polarbear -d polarbear_restore -v ON_ERROR_STOP=1
```
**Check:** no `ERROR` lines, and the last command exits 0 (`echo $?` prints `0`).

Compare it with production:

```bash
for db in polarbear polarbear_restore; do
  echo "== $db"
  sudo docker exec polarbear-postgres-1 psql -U polarbear -d $db -Atc \
    "select 'tenants', count(*) from tenants union all
     select 'users',   count(*) from \"user\" union all
     select 'api_keys',count(*) from api_keys"
done
```
**Check:** the `polarbear_restore` numbers are what you expect for that date.

**Swap it in.** For a few seconds the backend's database connections are cut
and some requests fail. Connect to the `postgres` maintenance database, not
to `polarbear`:

```bash
STAMP=$(date -u +%Y%m%d%H%M)
sudo docker exec -i polarbear-postgres-1 psql -U polarbear -d postgres -v ON_ERROR_STOP=1 <<SQL
ALTER DATABASE polarbear ALLOW_CONNECTIONS false;
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
 WHERE datname = 'polarbear' AND pid <> pg_backend_pid();
ALTER DATABASE polarbear RENAME TO polarbear_replaced_$STAMP;
ALTER DATABASE polarbear_restore RENAME TO polarbear;
ALTER DATABASE polarbear_replaced_$STAMP ALLOW_CONNECTIONS true;
SQL
sudo rm -f /var/tmp/polarbear-$RUN.sql.gz
```
**Check:** see [Checking Production After a Restore](#checking-production-after-a-restore).

The old data stays in `polarbear_replaced_<stamp>`. When you are sure the
restore is right, drop it:
`sudo docker exec polarbear-postgres-1 dropdb -U polarbear polarbear_replaced_<stamp>`.
To undo the swap, run the same rename block with the names reversed.

---

## B. Restore Meilisearch from a Dump

Meilisearch can only load a dump when it starts. So restoring it means
**search is down** while it imports. At today's size that takes seconds. At
100 merchants × 200 products expect under a minute.

### How the Master Key Is Handled Here

Every step below that needs the Meilisearch master key gets it through
`/opt/polarbear/backup.sh`. That is the same code the nightly backup uses, so
the key is extracted in exactly one place. It never appears on a command line,
in `ps`, in your shell history, or on screen:

- `sudo /opt/polarbear/backup.sh meili-request GET /stats [BASE_URL]` makes an
  authenticated call and prints the JSON.
- `/opt/polarbear/backup.sh meili-key` prints the key, but only into a pipe or
  `$(...)`. It refuses to print to a terminal. Below it only runs inside
  `sudo bash -c '...'`, where the key goes straight into the environment of
  `docker run -e MEILI_MASTER_KEY`.

### B1. Check the Dump First, Without Touching Production

This starts a throwaway Meilisearch on port 7701 with its own empty volume,
loads the dump, and shows what is inside. Production keeps running.

**On the VM:**

```bash
RUN=20260918T091701Z-3fa9c2      # <- the backup you chose (the part after meilisearch/, without .dump)
sudo gsutil cp gs://polarbear-backups-479000/meilisearch/$RUN.dump /var/tmp/restore.dump
sudo chmod 644 /var/tmp/restore.dump

sudo bash -c 'export MEILI_MASTER_KEY=$(/opt/polarbear/backup.sh meili-key) &&
  docker run -d --name meili-restore-test -p 127.0.0.1:7701:7700 \
    -e MEILI_MASTER_KEY -e MEILI_ENV=production \
    -v meili_restore_test:/meili_data -v /var/tmp/restore.dump:/restore.dump:ro \
    getmeili/meilisearch:v1.12 meilisearch --import-dump /restore.dump'

# Wait until the import finishes and the server answers
until curl -fsS http://127.0.0.1:7701/health >/dev/null 2>&1; do sleep 2; done; echo "up"

# Every index and its document count: the restored copy, then production
sudo /opt/polarbear/backup.sh meili-request GET /stats http://127.0.0.1:7701 | jq '.indexes | map_values(.numberOfDocuments)'
sudo /opt/polarbear/backup.sh meili-request GET /stats                       | jq '.indexes | map_values(.numberOfDocuments)'
```
**Check:** the first list has one `products_<tenant_id>` per merchant, with
the product counts you expect. The second is production, for comparison.

Remove the test copy:

```bash
sudo docker rm -f meili-restore-test && sudo docker volume rm meili_restore_test
```

### B2. Replace Production's Meilisearch Data

Only do this if B1 looked right. **Search is down from step 2 to step 5.**

**On the VM:**

```bash
cd /opt/polarbear
# 1. The dump (same as B1). Skip if /var/tmp/restore.dump is still there.
RUN=20260918T091701Z-3fa9c2
sudo gsutil cp gs://polarbear-backups-479000/meilisearch/$RUN.dump /var/tmp/restore.dump
sudo chmod 644 /var/tmp/restore.dump

# 2. Stop production Meilisearch (search is now down)
sudo docker compose -p polarbear -f compose.yml stop meilisearch

# 3. Move the current data aside (kept, not deleted). Uses the Meilisearch image,
#    which is already on the VM, so nothing new is downloaded.
STAMP=$(date -u +%Y%m%d%H%M)
sudo docker run --rm --entrypoint sh -v polarbear_meili_data:/meili_data getmeili/meilisearch:v1.12 \
  -c "mv /meili_data/data.ms /meili_data/data.ms.replaced-$STAMP"

# 4. Import the dump into the production volume, then remove that one-off container
sudo bash -c 'export MEILI_MASTER_KEY=$(/opt/polarbear/backup.sh meili-key) &&
  docker run -d --name meili-import -p 127.0.0.1:7701:7700 \
    -e MEILI_MASTER_KEY -e MEILI_ENV=production \
    -v polarbear_meili_data:/meili_data -v /var/tmp/restore.dump:/restore.dump:ro \
    getmeili/meilisearch:v1.12 meilisearch --import-dump /restore.dump'
until curl -fsS http://127.0.0.1:7701/health >/dev/null 2>&1; do sleep 2; done; echo "imported"
sudo docker rm -f meili-import

# 5. Start production Meilisearch on the restored data (search is back)
sudo docker compose -p polarbear -f compose.yml start meilisearch
until curl -fsS http://127.0.0.1:7700/health >/dev/null 2>&1; do sleep 2; done; echo "up"
sudo rm -f /var/tmp/restore.dump
```
**Check:** `sudo /opt/polarbear/backup.sh meili-request GET /stats | jq '.indexes | map_values(.numberOfDocuments)'`
shows the counts from B1. Then see [Checking Production After a Restore](#checking-production-after-a-restore).

To undo: stop Meilisearch as in step 2, then swap the directories back with
the same one-off container as step 3
(`-c "mv /meili_data/data.ms /meili_data/data.ms.bad-$STAMP && mv /meili_data/data.ms.replaced-<stamp> /meili_data/data.ms"`),
then start it again. Once you are sure the restore is good, free the space
with the same container and `-c "rm -rf /meili_data/data.ms.replaced-<stamp>"`.

### B3. Line the Vector Files Up with the Restored Catalog

Search combines Meilisearch with each tenant's FAISS files in
`gs://polarbear-indexes-479000/tenants/<tenant_id>/` (`faiss.bin`,
`doc_map.pkl`). These are rewritten on every catalog upload. If a merchant
uploaded a catalog **after** the dump you restored, their FAISS files are
newer than their restored catalog. Pick one:

- **Simplest:** ask that merchant to upload their catalog again. This rebuilds both.
- **Or** restore the FAISS files from the same time. List the versions and
  copy the right generation back:
  ```bash
  gcloud storage ls -a -l gs://polarbear-indexes-479000/tenants/<tenant_id>/
  gcloud storage cp "gs://polarbear-indexes-479000/tenants/<tenant_id>/faiss.bin#<generation>" \
                    gs://polarbear-indexes-479000/tenants/<tenant_id>/faiss.bin
  # same for doc_map.pkl, using the generation from the same upload
  ```
  Old versions are kept for at most 30 days, and at most 3 of them per file.

---

## C. Restore the Whole VM from a Disk Snapshot

Use this when the VM will not boot, its disk is damaged, or it was deleted.
**Everything written after the snapshot is lost.** Afterwards you can load a
newer Postgres or Meilisearch dump with A or B if one exists.

Pick the snapshot:

```bash
gcloud compute snapshots list --project polarbear-dev-479000 \
  --filter="sourceDisk~polarbear-services" --sort-by=~creationTimestamp \
  --format="table(name,creationTimestamp,status)"
SNAP=<name from the list>
NEWDISK=polarbear-services-restored-$(date -u +%Y%m%d%H%M)
```

Make a new disk from it. The original disk is not touched:

```bash
gcloud compute disks create $NEWDISK --source-snapshot $SNAP \
  --zone us-west1-b --type pd-standard --project polarbear-dev-479000
```
**Check:** the command prints the new disk with `STATUS READY`.

### C1. The VM Still Exists: Swap Its Boot Disk

Search is down from the stop to the start (about 2 minutes).

```bash
gcloud compute instances stop polarbear-services --zone us-west1-b --project polarbear-dev-479000
gcloud compute instances detach-disk polarbear-services --disk polarbear-services \
  --zone us-west1-b --project polarbear-dev-479000
gcloud compute instances attach-disk polarbear-services --disk $NEWDISK --boot \
  --zone us-west1-b --project polarbear-dev-479000
gcloud compute instances start polarbear-services --zone us-west1-b --project polarbear-dev-479000
```

The VM keeps its reserved internal IP, network tags (the firewall rules
depend on them), service account and scopes. Only the disk changed.

### C2. The VM Is Gone: Recreate It

```bash
gcloud compute instances create polarbear-services \
  --zone us-west1-b --machine-type e2-micro --project polarbear-dev-479000 \
  --disk=name=$NEWDISK,boot=yes,auto-delete=no \
  --network default --subnet default \
  --private-network-ip polarbear-services-internal \
  --tags postgres-server,meilisearch-server \
  --metadata-from-file startup-script=infrastructure/gcp/vm/startup-script.sh \
  --service-account 399780699896-compute@developer.gserviceaccount.com \
  --scopes https://www.googleapis.com/auth/devstorage.read_write,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/pubsub,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/trace.append
```

`--network default --subnet default` puts it on the same network as before,
so the firewall rules (defined per network) cover it.
`--private-network-ip polarbear-services-internal` gives it back `10.138.0.2`,
which is the address the backend uses. The tags put it back behind the same
firewall rules. `devstorage.read_write` lets the nightly backup upload again.
The startup-script is the secret-free one from the repo. Run it from the repo root.

### After C1 or C2

1. Wait about a minute, then **on the VM**: `sudo docker ps`.
   **Check:** both `polarbear-postgres-1` and `polarbear-meilisearch-1` are `Up`.
   They restart on their own (`restart: always`), and the startup-script runs
   `docker compose up -d` on boot.
1b. **If the snapshot is older than the last secret rotation**, the disk
   comes back with the OLD Postgres password and Meilisearch master key, both in
   compose.yml and inside the Postgres data. The backend, pinned to the new secrets
   in Secret Manager, will fail to connect. Fix it by rotating onto fresh values:
   `./infrastructure/gcp/35-rotate-datastore-secrets.sh` (section E). The
   pre-rotation snapshot is `polarbear-services-pre-rotation-<date>`.
2. Move the snapshot schedule to the new disk, or the new disk is not
   protected:
   ```bash
   gcloud compute disks add-resource-policies $NEWDISK --zone us-west1-b \
     --resource-policies polarbear-daily-snapshots --project polarbear-dev-479000
   ```
3. **On the VM:** `sudo crontab -l | grep backup.sh`. The cron line comes back
   with the disk. **Check:** one line.
4. Run [Checking Production After a Restore](#checking-production-after-a-restore).
5. Keep the old disk `polarbear-services` until you are sure. It still
   costs money while it exists. Delete it later with
   `gcloud compute disks delete polarbear-services --zone us-west1-b`.

---

## D. Rebuild compose.yml on a Fresh VM

Use this when a VM has no `/opt/polarbear/compose.yml`, for example a brand-new VM
built from a plain image instead of a snapshot. The startup-script refuses to start
anything without it and logs `ERROR: /opt/polarbear/compose.yml is missing`.

The file is rendered from the repo's `infrastructure/gcp/vm/compose.template.yml`
(compose.yml with `__POSTGRES_PASSWORD__` and `__MEILI_MASTER_KEY__` placeholders)
and the `in-use` versions in Secret Manager. The values travel from Secret Manager to the VM
through a pipe only.

From the repo root on the Mac:

```bash
# 1. Put the helper and the template on the VM
gcloud compute scp infrastructure/gcp/vm/datastore-secrets.sh infrastructure/gcp/vm/compose.template.yml   polarbear-services:/tmp/ --zone us-west1-b --project polarbear-dev-479000
gcloud compute ssh polarbear-services --zone us-west1-b --project polarbear-dev-479000 --command   'sudo mkdir -p /opt/polarbear &&
   sudo install -o root -g root -m 0700 /tmp/datastore-secrets.sh /opt/polarbear/datastore-secrets.sh &&
   sudo install -o root -g root -m 0644 /tmp/compose.template.yml /opt/polarbear/compose.template.yml'

# 2. Render compose.yml: secret values go Secret Manager -> pipe -> the VM's stdin
{ gcloud secrets versions access in-use --secret polarbear-postgres-password --project polarbear-dev-479000; echo
  gcloud secrets versions access in-use --secret polarbear-meili-master-key  --project polarbear-dev-479000; echo
} | gcloud compute ssh polarbear-services --zone us-west1-b --project polarbear-dev-479000 --command   'sudo /opt/polarbear/datastore-secrets.sh render /opt/polarbear/compose.template.yml'

# 3. Start the containers
gcloud compute ssh polarbear-services --zone us-west1-b --project polarbear-dev-479000 --command   'cd /opt/polarbear && sudo docker compose up -d'
```
**Check:** step 2 prints `rendered /opt/polarbear/compose.yml … (root:root 600)`,
and `sudo docker ps` shows both containers `Up`.

If `in-use` is not accepted as a version name, find the numbers with
`gcloud secrets describe polarbear-postgres-password --format='value(versionAliases)'`
and use them instead.

A fresh Postgres volume starts empty, with the password from compose.yml. Now load
the data: [A](#a-restore-postgres-from-a-dump) for Postgres and
[B](#b-restore-meilisearch-from-a-dump) for Meilisearch. Then run
`infrastructure/gcp/40-install-backups.sh` so backups and cron are back, and
[check production](#checking-production-after-a-restore).

---

## E. Rotate the Secrets Again

Rotate when a value may have been seen by anyone or anything it shouldn't
have, and otherwise about once a year. **About 2–3 minutes of search downtime.**

```bash
DRY_RUN=1 ./infrastructure/gcp/35-rotate-datastore-secrets.sh   # read the plan
./infrastructure/gcp/35-rotate-datastore-secrets.sh
```

The script works in two phases.

**Phase 1, no downtime.** It snapshots the disk. If the backend still has
`DATABASE_URL` / `MEILI_MASTER_KEY` as plain env vars, it stores their
**current** values in Secret Manager and switches Cloud Run to read them from there,
with the values unchanged (`gcloud run services replace` with the service's own spec,
validated with `--dry-run` first). It then checks that production behaves exactly as before.
If this phase fails, it puts Cloud Run back as it was and destroys the
versions it stored. Nothing on the VM has been touched at that point.

**Phase 2, about 2–3 minutes of downtime.** It generates new values that nobody sees,
updates compose.yml and the Postgres user on the VM, restarts both containers, and
re-pins Cloud Run to the new versions. That re-pin is a plain `--update-secrets`,
the same type as before, so nothing risky happens inside the window. If anything fails
before production is verified, it puts the VM back on the old values and routes
Cloud Run back to the phase-1 revision, which reads the old values from Secret
Manager, and says exactly what it restored.

**After success** it moves the `in-use` alias to the new versions, **destroys** the
versions holding the old (leaked) values and checks they read `DESTROYED`, proves the
old values are rejected, and cleans up. If the destroy fails, production is
fine, but it prints the exact `gcloud secrets versions destroy …` commands to run.
Destroying is safe at that point because no rollback can reach the old
values any more. **Never route traffic back to a revision from before a rotation.**
It would reference destroyed versions or dead values.

Done by hand, the same thing is: new version in Secret Manager → change the VM
(compose.yml + `ALTER USER`) → `docker compose up -d` → `gcloud run services
update … --update-secrets NAME=secret:NEWVERSION` (re-pin) → verify → destroy the
old versions. Cloud Run only picks up a new version when you re-pin it and a new
revision starts.

Versions left behind by a rolled-back run hold values that were never in service.
Destroy them when convenient with
`gcloud secrets versions destroy <N> --secret <name> --project polarbear-dev-479000`.

For the SMTP password: add a new version of `polarbear-smtp-password` yourself,
then re-run `infrastructure/gcp/50-configure-smtp.sh <sender>`. It re-pins to the
newest enabled version.

---

## Checking Production After a Restore

From a checkout of this repo:

```bash
bash -c 'source infrastructure/gcp/lib/common.sh
         source infrastructure/gcp/lib/verify-production.sh
         verify_production && finish'
```

This checks `/health` returns 200, that a bogus search key gets 401 (so the
backend reaches Postgres), and that a real search returns results (so the
backend reaches Meilisearch). It also checks the serving Cloud Run revision
has logged no errors. **Check:** `verify: ALL CHECKS PASSED`.

Also open the dashboard, log in, and search your own store.

---

## Where This Came From

The GCP pieces were set up with the scripts in `infrastructure/gcp/`, run
in order. Each one explains at the top what it changes and how to undo it,
and each supports `DRY_RUN=1`:

| Script | Does |
|---|---|
| `10-move-backend-to-internal-network.sh` | Cloud Run → VM over the internal IP (Direct VPC egress) |
| `20-close-public-database-ports.sh` | Postgres/Meilisearch firewall rules limited to the Cloud Run subnet |
| `35-rotate-datastore-secrets.sh` | Postgres password + Meilisearch key rotated into Secret Manager; secret-free startup-script |
| `30-enable-vm-storage-write.sh` | VM allowed to write to Cloud Storage (one stop/start) |
| `40-install-backups.sh` | Snapshot schedule, backup bucket, index-bucket versioning, backup script and cron |
| `50-configure-smtp.sh` | Password-reset email through Gmail SMTP (password from Secret Manager) |
| `vm/backup.sh` | The nightly backup itself, installed as `/opt/polarbear/backup.sh` |
| `vm/datastore-secrets.sh` | VM-side rotation and rebuild helper, installed as `/opt/polarbear/datastore-secrets.sh` |
| `vm/startup-script.sh` | The VM's secret-free boot script (instance metadata `startup-script`) |
| `vm/compose.template.yml` | compose.yml without its two secret values (section D) |

The run order was 10 → 20 → 35 → 30 → 40, then 50.
