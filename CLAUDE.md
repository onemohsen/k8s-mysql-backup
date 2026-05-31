# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-purpose Alpine container (`kubectl` + `rclone`) that runs `crond` and, on a
schedule, dumps a fixed list of MySQL pods living in **different Kubernetes namespaces**
and uploads the gzipped dumps to an rclone remote. It is deployed both locally (plain
`docker compose`) and on **Coolify**. There is no application code — the logic is three
shell scripts plus Docker/compose plumbing.

## Commands

```bash
# Build
docker compose build

# Run a ONE-OFF backup now (the main way to test end-to-end), then exit
docker compose run --rm mysql-backup once

# Run as the scheduled daemon (installs crond, stays up)
docker compose up -d
docker compose logs -f

# Syntax-check the scripts after editing (there is no test suite)
bash -n backup.sh && bash -n entrypoint.sh

# Inspect the rendered config (verify env interpolation + which volumes mount)
docker compose config                       # local view (merges override)
docker compose -f docker-compose.yml config # Coolify view (no override)
```

The `once` argument is handled by `entrypoint.sh` and bypasses cron — use it for every
test. Inside a running container, `/usr/local/bin/backup.sh` also runs one backup.

## Core architecture

**Dumps happen inside the pods, never here.** Per pod, `backup.sh` first lists databases
(`mysql -N -B -e 'SHOW DATABASES'`), skips system schemas + `EXCLUDE_DBS`, then runs one
`kubectl exec ... -- sh -c "mysqldump ... --databases <db>"` **per database**, piping
stdout through `gzip` into its own `/backups/<ns>-<selector>-<db>-<stamp>.sql.gz`. MySQL
credentials are read from the **pod's own env vars** — passed via `MYSQL_PWD` and with the
`$VAR` references escaped so they expand inside the pod (never on the backup host, never on
the in-pod process list). Preserve this property in any change to the dump logic.

**One file per database, validated.** Each dump uses `--databases <db>` (so the file is
self-contained: `CREATE DATABASE IF NOT EXISTS` + `USE`) and restore-friendly flags
(`--single-transaction --quick --routines --triggers --events --no-tablespaces`). With
`set -o pipefail`, a failed `mysqldump` fails the whole pipe; each file is then checked
with `gzip -t` and a ≥1KB size floor before it counts as success. Note: per-DB snapshots
are individually consistent but not consistent *across* databases of the same pod.

**The `TARGETS` DSL is the central contract.** A whitespace-separated list, one entry per
DB, each `namespace/selector[/USER_VAR/PASS_VAR]`:
- `namespace/selector` → dumps as `root`, password from `$PASSWORD_VAR`.
- `namespace/selector/USER_VAR/PASS_VAR` → user and password read from those in-pod env vars.

`selector` is a **label selector** (e.g. `app=mysql`), resolved to the current
running pod at backup time via `kubectl get pod -l <selector> --field-selector=status.phase=Running`.
This is deliberate: Deployment/ReplicaSet pod names carry random suffixes that change on
redeploy, so never hardcode pod names. Parsing splits on `/`, which is safe because
selectors and env-var names contain no slashes.

**`entrypoint.sh` works around cron's bare environment.** `crond` jobs don't inherit the
container env, so the entrypoint greps the relevant vars out of `printenv`, writes them to
`/etc/backup.env`, and the crontab line `source`s that file before running `backup.sh`.
If you add a new env var that `backup.sh` reads, you must also add it to that grep filter,
or it will be missing under cron (but present in `once` mode — a classic gotcha).

**Failures are aggregated, not fail-fast.** `backup.sh` sets `FAILED=1` and continues on a
bad target/dump/upload so one broken DB doesn't block the others; it exits non-zero at the
end if anything failed. A dump under ~1KB is treated as a likely failure.

## Config injection: local vs Coolify (important)

The same image runs in two environments that supply config differently. Keep both working.

| | Env vars | kubeconfig + rclone.conf | backups |
|---|---|---|---|
| **Local** | `.env` (gitignored), auto-read by compose for `${VAR}` interpolation | `./config:/config:ro`, added **only** by `docker-compose.override.yml` (gitignored) | named volume + `./backups` |
| **Coolify** | set in the Coolify UI; `${VAR}` refs become editable fields | **Storages → File Mount** at `/config/kubeconfig` and `/config/rclone.conf` (paste contents) | named volume `backups` |

- `docker-compose.yml` is the Coolify-facing file: `environment:` uses `${VAR}` (with
  `${VAR:?}` required-guards on `TARGETS` and `RCLONE_PATH`), declares the `backups` named
  volume, and declares **no** config bind mount.
- `docker-compose.override.yml` is local-only and **gitignored** so Coolify never sees it;
  `docker compose` auto-merges it to add the `./config` bind mount for testing.
- Do **not** add a `/config` file bind mount to the committed compose: Coolify creates file
  bind-mounts as directories (coollabsio/coolify#8107). Config files go through the
  Storages UI there.
- The Dockerfile pins `KUBECONFIG=/config/kubeconfig` and `RCLONE_CONFIG=/config/rclone.conf`.

## Constraints when editing

- Anything secret or environment-specific (`.env`, `config/`, `backups/`, dumps,
  `docker-compose.override.yml`) is gitignored and must stay out of git.
- The kubeconfig's `server:` must be reachable from the host running the container (not
  `127.0.0.1`); the kubeconfig user needs `pods/exec` in every target namespace.
- A per-DB app user only dumps what it has privileges on (and `--routines/--triggers/
  --events` need extra grants) — fall back to root creds for that target if dumps fail.
