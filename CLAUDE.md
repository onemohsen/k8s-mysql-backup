# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-purpose Alpine container (`kubectl` + `rclone`) that runs `crond` and, on a
schedule, dumps a fixed list of MySQL pods living in **different Kubernetes namespaces**
and uploads the gzipped dumps to an rclone remote. It is deployed both locally (plain
`docker compose`) and on **Coolify**. There is no application code — the logic is two
shell scripts (`backup.sh`, `entrypoint.sh`) plus Docker/compose plumbing.

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
docker compose config
```

The `once` argument is handled by `entrypoint.sh` and bypasses cron — use it for every
test. Inside a running container, `/usr/local/bin/backup.sh` also runs one backup.

## Core architecture

**`TARGETS` is the central contract.** A space-separated list (one entry per DB pod), each
`namespace/pod/user/password`, parsed with `IFS='/' read -r ns pod user pass` — so the
password is the *remainder* and may itself contain `/`. Pods are referenced by **exact
name** (the deployment doesn't recreate them), no label-selector resolution. The loop runs
under `set -f` so passwords containing `* ? [` aren't glob-expanded during word-splitting.

**Credentials go in via stdin, never argv.** The `pod_mysql` helper does
`printf '%s\n' "$pass" | kubectl exec -i ... -- sh -c 'IFS= read -r MYSQL_PWD; export
MYSQL_PWD; exec "$@"' _ <binary> <args...>`. The password arrives on the pod's stdin (off
the process list); the command + args pass as real argv via `exec "$@"` (no shell
re-parsing, so special chars in user/db/flags are safe). **Preserve this** — do not fall
back to interpolating the password into an `sh -c` string.

**One file per database, dumped in-pod then copied out.** Per pod, `backup.sh` lists
databases (`mysql -N -B -e 'SHOW DATABASES'`), skips system schemas + `EXCLUDE_DBS`, then
for each DB calls `dump_one_db`, which does the slow work **inside the pod**:
`mysqldump ... <db> | gzip > /tmp/...sql.gz` in-pod, verifies it in-pod (gzip
frame + the `-- Dump completed` footer), and only then `kubectl cp`s the finished file to
`/backups/<ns>-<pod>-<db>-<stamp>.sql.gz` and **re-verifies it on the host** (kubectl cp can
itself truncate). **WHY in-pod, not a streamed `mysqldump | gzip` over `kubectl exec`:** a
long-lived exec stream of a large dump gets silently truncated — `kubectl exec` can return 0
on a dropped stream and `gzip` then wraps the partial output into a *valid* `.gz`. Doing the
dump in-pod means only a small, already-verified file crosses the wire (and tiny status
lines, which can't meaningfully truncate). The DB is dumped **positionally** (`mysqldump … <db>`),
NOT with `--databases`, so the file holds only table DDL + data — no `CREATE DATABASE`/`USE`
— and restores into any target DB (`mysql <target> < dump.sql`), like spatie/db-dumper. The
flag set lives in `DUMP_FLAGS` (overridable) + `EXTRA_DUMP_FLAGS` (appended), and
`EXCLUDE_TABLES` adds per-DB `--ignore-table` flags. A
failing dump is retried (`DUMP_RETRIES`/`DUMP_BACKOFF`), then removed. **Do not add
`--compact`/`--skip-comments` to `DUMP_FLAGS`** — they delete the footer the completeness
check relies on. Target pods must have `gzip` and `tar` (kubectl cp uses tar). Per-DB
snapshots are individually consistent but not consistent *across* a pod's DBs.

**`entrypoint.sh` works around cron's bare environment.** `crond` jobs don't inherit the
container env, so the entrypoint greps the relevant vars out of `printenv`, **single-quotes
each value** (so a value with spaces — multi-target `TARGETS`, multi-flag `DUMP_FLAGS` —
doesn't break when cron's `/bin/sh` sources it), writes them to `/etc/backup.env`, and the
crontab line `source`s that file before running `backup.sh`. If you add a new env var that
`backup.sh` reads, you must also add it to that grep filter, or it will be missing under
cron (but present in `once` mode — a classic gotcha).

**Failures are aggregated, not fail-fast.** `backup.sh` sets `FAILED=1` and continues on a
bad target/dump/upload so one broken DB doesn't block the others; it exits non-zero at the
end if anything failed. A dump under ~1KB is treated as a likely failure.

## Config & deployment

`docker-compose.yml` is used both locally and by Coolify (one file). Settings are `${VAR}`
refs (with `${VAR:?}` required-guards on `TARGETS` and `RCLONE_PATH`); volumes are
`./config:/config` (kubeconfig + rclone.conf) and the named `backups` volume. The Dockerfile
pins `KUBECONFIG=/config/kubeconfig` and `RCLONE_CONFIG=/config/rclone.conf`.

| | settings | kubeconfig + rclone.conf |
|---|---|---|
| **Local** | `.env` (gitignored), auto-read by compose | files in `./config/` (gitignored) |
| **Coolify** | env vars in the UI (`${VAR}` become editable fields) | files placed in the `/config` mount's host dir on the server (the dashboard can't manage Compose volumes) — see COOLIFY.md |

- **Quote `TARGETS` in `.env`.** Passwords often contain `#`; an unquoted `#` in `.env` is a
  comment and the value is silently truncated. (The Coolify UI stores it literally, so no
  quotes needed there.) Verify with `docker compose config | grep TARGETS:`.
- If you add a new env var that `backup.sh` reads, also add it to the `printenv` grep in
  `entrypoint.sh` (the cron job runs with a bare env and sources only those).

## Constraints when editing

- Anything secret or environment-specific (`.env`, `config/`, `backups/`, dumps) is
  gitignored and must stay out of git. This is a **public repo** — no real namespaces, pod
  names, buckets, or credentials in committed files.
- The kubeconfig's `server:` must be reachable from the host running the container (not
  `127.0.0.1`); the kubeconfig user needs `pods/exec` in every target namespace.
- A target's user only dumps what it has privileges on (`--routines/--triggers/--events`
  need extra grants) — use a more privileged account or trim `DUMP_FLAGS` if dumps fail.
