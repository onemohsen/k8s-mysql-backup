# MySQL → S3 daily backup container

A small Alpine container with `kubectl` + `rclone` that dumps a fixed list of MySQL
pods (each in its own namespace) once a day and uploads the gzipped dumps to S3,
keeping a local copy too. **Each database gets its own file** — not one big
`--all-databases` blob — so you can restore a single DB independently.

## How it works
- You list the pods to back up in `TARGETS` as `namespace/pod/user/password` entries.
- For each pod it lists the databases (skipping `information_schema`,
  `performance_schema`, `sys`, `mysql`, plus anything in `EXCLUDE_DBS`) and dumps each
  one (`mysqldump <db>`, positional — no `CREATE DATABASE`/`USE`, so it restores into any
  target DB) to its own gzipped file:
  `<namespace>-<pod>-<database>-<timestamp>.sql.gz`.
- The dump runs **entirely inside the pod**: `mysqldump | gzip` writes a temp `.sql.gz`
  to the pod's `/tmp`, and the dump is verified *in-pod* (gzip frame + the `-- Dump
  completed` footer `mysqldump` writes last). Only then is the small, finished file pulled
  out with `kubectl cp` and re-verified on the host. The slow dump never streams over a
  long-lived `kubectl exec` connection — that's what silently truncates large dumps
  (`kubectl exec` can end with exit 0 after a dropped stream, producing a *valid* gzip of a
  *partial* dump). The password is fed to mysqldump over **stdin**, so it never appears on
  a process list. A failed/truncated dump is retried (`DUMP_RETRIES`), then removed and
  flagged, and the run exits non-zero. (Target pods need `gzip` and `tar` — `tar` is what
  `kubectl cp` uses; both are present in the standard MySQL images.)
- Output is gzipped and written to `/backups` (a Docker named volume).
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
The dump holds only table DDL + data — **no `CREATE DATABASE` / `USE`** — so it restores
into **whatever database you name**, not a fixed one. Create (or pick) the target DB, then
pipe the dump into it:
```bash
# locally, into a DB of your choosing (e.g. test2)
mysql -uroot -e 'CREATE DATABASE IF NOT EXISTS test2 CHARACTER SET utf8mb4'
gunzip -c app-one-app-one-mysql-0-mydb-2026-06-01-0200.sql.gz \
  | mysql -uroot --max-allowed-packet=1G test2

# or into a pod
gunzip -c ...sql.gz \
  | kubectl exec -i -n app-one app-one-mysql-0 -- \
      sh -c 'mysql -ubackup_user -p"p4ssw0rd" --max-allowed-packet=1G target_db'
```
Name the target DB as the last `mysql` argument (`… test2` / `… target_db`). Create it as
`utf8mb4` for Laravel data — the DB-level default charset isn't in the dump (table-level
charsets are). `--max-allowed-packet=1G` on the **restore** side matters too: a single
large row (e.g. Telescope JSON) produces a big `INSERT` the server will reject under the
default packet limit, surfacing as a "syntax error near ..." or "MySQL server has gone
away" mid-file.
If a row exceeds the server's own limit, raise it once:
`mysql ... -e 'SET GLOBAL max_allowed_packet=1073741824;'`.
