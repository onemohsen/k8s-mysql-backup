# Deploying on Coolify

Runs as a single always-on container that wakes itself on `CRON_SCHEDULE` and
dumps each MySQL pod to your rclone remote. No HTTP port, no domain.

## 1. Create the resource
- **+ New** → **Docker Compose** (Public/Private Repository, build pack
  **Docker Compose**), pointed at this repo / the `docker` directory.
- Coolify reads `docker-compose.yml` and builds the image from the `Dockerfile`.
- `.env` is gitignored, so Coolify never sees it — settings come from the UI (step 2),
  config files from the mounted dir (step 3).

## 2. Environment Variables (Settings → Environment Variables)
The `${VAR}` refs in the compose file show up here automatically. Set:

| Variable        | Example                                                   | Notes |
|-----------------|-----------------------------------------------------------|-------|
| `TARGETS`       | `app-one/app-one-mysql-0/backup_user/p4ssw0rd ...`       | **required**, space-separated, one entry per DB |
| `RCLONE_PATH`   | `my-bucket/mysql-backups`                                 | **required**, bucket/path |
| `RCLONE_REMOTE` | `s3`                                                      | remote name in `rclone.conf` |
| `CRON_SCHEDULE` | `0 2 * * *`                                               | daily 02:00 |
| `TZ`            | `Asia/Tehran`                                             | |
| `EXCLUDE_DBS`   | `scratch_db`                                              | optional, extra DBs to skip |
| `RETENTION_DAYS`| `7`                                                       | |

`TARGETS` entry format: `namespace/pod/user/password` (exact pod name; password may
contain `/`). Paste the value as one line — in the Coolify UI it's stored literally, so
the `#` in passwords is fine (unlike a raw `.env`, which needs the value double-quoted).

> `TARGETS` and `RCLONE_PATH` use the `${VAR:?}` required syntax, so Coolify
> blocks the deploy (red border) until you set them.

## 3. Config files (kubeconfig + rclone.conf)
Volume mounts can't be managed from the dashboard for Compose apps, so the mount is
declared in `docker-compose.yml` (`./config:/config`) and you place the two files in its
host directory on the server:

1. **Storages** tab → note the host source path shown for the `/config` mount.
2. SSH to the Coolify server and drop the two files there:
   ```bash
   cp kubeconfig   <that-path>/kubeconfig
   cp rclone.conf  <that-path>/rclone.conf
   ```
   - kubeconfig `server:` must be reachable **from the Coolify host** (not `127.0.0.1`).
   - `rclone config file` shows where your local rclone.conf lives.

The image already points `KUBECONFIG=/config/kubeconfig` and
`RCLONE_CONFIG=/config/rclone.conf` at these paths.

## 4. Backups storage
`docker-compose.yml` declares a named volume `backups` mounted at `/backups`, so
dumps survive redeploys. It appears under Storages; nothing to configure.

## 5. Deploy & test
- **Deploy**, then watch **Logs** for `Cron schedule installed: …`.
- Don't wait for 02:00 — open the container **Terminal** (or **Execute Command**)
  and run one backup now:
  ```
  /usr/local/bin/backup.sh
  ```
  Look for `Finished successfully` and confirm objects land in your bucket.

## Notes
- The kubeconfig user needs `pods/exec` rights in each target namespace (this also covers
  `kubectl cp`, which runs over exec).
- Target pods must have `gzip` and `tar` (the dump is gzipped in-pod and `kubectl cp` uses
  `tar`); both ship in the standard MySQL images.
- Every non-system database is dumped to its own file; add `EXCLUDE_DBS` (space-
  separated) to skip more.
- A user only dumps what it has privileges on (events/routines need extra grants); if its
  dumps fail, use a more privileged account for that target, or trim with `DUMP_FLAGS`.
- Alternative to the built-in cron: drive backups from Coolify **Scheduled Tasks**
  (command `/usr/local/bin/backup.sh once`) for a manual "run now" button and run
  history in the UI. The container still runs its own cron either way.
