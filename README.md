# MySQL → S3 daily backup container

A small Alpine container with `kubectl` + `rclone` that dumps a fixed list of MySQL
pods (each in its own namespace) once a day and uploads the gzipped dumps to S3,
keeping a local copy too. **Each database gets its own file** — not one big
`--all-databases` blob — so you can restore a single DB independently.

## How it works
- You list the pods to back up in `TARGETS` as `namespace/pod/user/password` entries.
- For each pod it lists the databases (skipping `information_schema`,
  `performance_schema`, `sys`, `mysql`, plus anything in `EXCLUDE_DBS`) and runs one
  `mysqldump --databases <db>` per database, gzipped to its own file:
  `<namespace>-<pod>-<database>-<timestamp>.sql.gz`.
- The dump happens *inside* the pod via `kubectl exec`. The password is fed to
  mysql/mysqldump over **stdin**, so it never appears on a process list and special
  characters can't be re-parsed by a shell.
- Each file is verified three ways before it counts as success: `mysqldump`'s own exit
  status, the gzip frame (`gzip -t`), and the in-band `-- Dump completed` footer that
  `mysqldump` writes last. This catches a **silently truncated** stream (which `kubectl
  exec` can end with exit 0, producing a *valid* gzip of a *partial* dump). A failed or
  truncated dump is retried (`DUMP_RETRIES`), then removed and flagged, and the run exits
  non-zero.
- Output is gzipped and written to `/backups` (a host volume).
- `rclone copy` pushes `/backups` to your S3 remote.
- Old local dumps are pruned after `RETENTION_DAYS` — but only after a clean run that
  uploaded successfully, so a streak of failures can't age out the last good local copy.
- `crond` runs the whole thing on `CRON_SCHEDULE`.

> Deploying on **Coolify**? See [COOLIFY.md](./COOLIFY.md). The steps below are for
> running locally with `docker compose`.

## Setup (3 steps)

### 1. Drop your two config files into ./config
```bash
mkdir -p config backups
cp ~/.kube/config            config/kubeconfig
cp ~/.config/rclone/rclone.conf  config/rclone.conf
```
⚠️ Your kubeconfig must point at an address the container can reach. If it points at
`127.0.0.1` / `localhost`, edit `config/kubeconfig` and replace that with the cluster's
real IP/hostname (localhost inside the container is NOT your host).

### 2. Create your .env
All settings live in `.env` (gitignored). Copy the template and edit it:
```bash
cp .env.example .env
```
Set `TARGETS`, `RCLONE_REMOTE`, `RCLONE_PATH` (bucket/path), `TZ`, and
`CRON_SCHEDULE`. Set `TARGETARCH=arm64` if `uname -m` says `aarch64`.

`TARGETS` is one entry per DB, `namespace/pod/user/password`, **space-separated on a
single line and wrapped in double quotes**:
```bash
TARGETS="app-one/app-one-mysql-0/backup_user/p4ssw0rd app-two/app-two-mysql-0/backup_user/an0ther#pass"
```
- **pod** = the exact pod name (`kubectl get pod -n <namespace>`).
- **password** = everything after the 3rd `/`, so it may itself contain `/`.
- ⚠️ **Quote the value.** Passwords often contain `#`, and the `.env` parser treats an
  unquoted `#` as a comment and silently truncates the value.

### 3. Build and run
```bash
docker compose build
docker compose up -d
docker compose logs -f          # watch it
```

## Test it immediately (don't wait until 2am)
```bash
docker compose run --rm mysql-backup once
```
This runs one backup right now and exits. Check ./backups/ and your S3 bucket.

## Common tweaks
- **Skip extra databases** → set `EXCLUDE_DBS="db1 db2"` (system schemas are always skipped).
- **Skip disposable tables (Laravel Telescope etc.)** → set
  `EXCLUDE_TABLES="telescope_entries telescope_entries_tags telescope_monitoring"`. Bare
  table names, applied to every dumped DB; they bloat dumps and are safe to drop.
- **Restricted user can't dump events/routines** → override the whole flag set, e.g.
  `DUMP_FLAGS="--single-transaction --quick --no-tablespaces"`.
- **Find pod names** → `kubectl get pod -n <namespace>`.
- **Check a user can list/dump** → `kubectl exec -n NS POD -- sh -c 'mysql -uUSER -pPASS -e "SHOW DATABASES"'`.

## Restore a single database
```bash
gunzip -c app-one-app-one-mysql-0-mydb-2026-06-01-0200.sql.gz \
  | kubectl exec -i -n app-one app-one-mysql-0 -- \
      sh -c 'mysql -ubackup_user -p"p4ssw0rd" --max-allowed-packet=1G'
```
Each file carries `CREATE DATABASE IF NOT EXISTS` + `USE`, so it restores standalone.
`--max-allowed-packet=1G` on the **restore** side matters too: a single large row (e.g.
Telescope JSON) produces a big `INSERT` the server will reject under the default packet
limit, surfacing as a "syntax error near ..." or "MySQL server has gone away" mid-file.
If a row exceeds the server's own limit, raise it once:
`mysql ... -e 'SET GLOBAL max_allowed_packet=1073741824;'`.
