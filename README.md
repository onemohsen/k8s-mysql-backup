# MySQL → S3 daily backup container

A small Alpine container with `kubectl` + `rclone` that dumps a fixed list of MySQL
pods (each in its own namespace) once a day and uploads the gzipped dumps to S3,
keeping a local copy too. **Each database gets its own file** — not one big
`--all-databases` blob — so you can restore a single DB independently.

## How it works
- You list the pods to back up in `TARGETS`. Each pod is found by **label selector**
  at runtime, so it keeps working after redeploys (no hardcoded pod-name suffixes).
- For each pod it lists the databases (skipping `information_schema`,
  `performance_schema`, `sys`, `mysql`, plus anything in `EXCLUDE_DBS`) and runs one
  `mysqldump --databases <db>` per database, gzipped to its own file:
  `<namespace>-<selector>-<database>-<timestamp>.sql.gz`.
- The dump happens *inside* the pod via `kubectl exec`, so credentials never leave it —
  user/password are read from the pod's own env vars (passed via `MYSQL_PWD`).
- Each file is integrity-checked (`gzip -t`) before upload; a failed or truncated dump
  is removed and flagged, and the run exits non-zero.
- Output is gzipped and written to `/backups` (a host volume).
- `rclone copy` pushes `/backups` to your S3 remote.
- Old local dumps are pruned after `RETENTION_DAYS`.
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

`TARGETS` is one entry per DB, **space-separated on a single line**. Two forms:
```bash
# namespace/selector                   -> user=root, password from $PASSWORD_VAR
# namespace/selector/USER_VAR/PASS_VAR -> user & password from those in-pod env vars
TARGETS=app-one/app=mysql app-two/app=mysql/MYSQL_USER/MYSQL_PASSWORD
```
- **selector** = a label selector that resolves to the running pod. Confirm the real
  labels with `kubectl get pod -n <namespace> --show-labels`.
- **USER_VAR / PASS_VAR** = names of env vars that exist *inside* the pod (check with
  `kubectl exec -n <ns> <pod> -- env | grep -i mysql`). The credentials never leave
  the cluster.

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
- **Per-pod user/password** → append both env var names: `ns/selector/USER_VAR/PASS_VAR`.
- **Restricted app user can't dump events/routines** → that user may lack privileges;
  use the root var for that target, or add overrides via `EXTRA_DUMP_FLAGS`.
- **Find the right env var names** → `kubectl exec -n NS POD -- env | grep -i mysql`.
- **Find the right label** → `kubectl get pod -n NS --show-labels`.

## Restore a single database
```bash
gunzip -c app-one-app_mysql-mydb-2026-06-01-0200.sql.gz \
  | kubectl exec -i -n app-one <pod> -- sh -c 'mysql -u root -p"$MYSQL_ROOT_PASSWORD"'
```
Each file carries `CREATE DATABASE IF NOT EXISTS` + `USE`, so it restores standalone.
- **Per-pod single DB instead of --all-databases** → edit `backup.sh`.
