# Deploying on Coolify

Runs as a single always-on container that wakes itself on `CRON_SCHEDULE` and
dumps each MySQL pod to your rclone remote. No HTTP port, no domain.

## 1. Create the resource
- **+ New** → **Docker Compose** (Public/Private Repository, build pack
  **Docker Compose**), pointed at this repo / the `docker` directory.
- Coolify reads `docker-compose.yml` and builds the image from the `Dockerfile`.
- `docker-compose.override.yml` and `.env` are gitignored, so Coolify never sees
  them — config comes from the UI instead (steps 2–3).

## 2. Environment Variables (Settings → Environment Variables)
The `${VAR}` refs in the compose file show up here automatically. Set:

| Variable        | Example                                                   | Notes |
|-----------------|-----------------------------------------------------------|-------|
| `TARGETS`       | `app-one/app=mysql/MYSQL_USER/MYSQL_PASSWORD app-two/app=mysql/MYSQL_USER/MYSQL_PASSWORD` | **required**, space-separated, one entry per DB |
| `RCLONE_PATH`   | `my-bucket/mysql-backups`                                 | **required**, bucket/path |
| `RCLONE_REMOTE` | `s3`                                                      | remote name in `rclone.conf` |
| `CRON_SCHEDULE` | `0 2 * * *`                                               | daily 02:00 |
| `TZ`            | `Asia/Tehran`                                             | |
| `PASSWORD_VAR`  | `MYSQL_ROOT_PASSWORD`                                     | used only by entries without `/USER_VAR/PASS_VAR` |
| `RETENTION_DAYS`| `7`                                                       | |

`TARGETS` entry format: `namespace/selector` (user=root, password from
`$PASSWORD_VAR`) or `namespace/selector/USER_VAR/PASS_VAR` (user + password read
from those env vars **inside** the pod). `selector` is a label selector resolved
to the running pod at backup time — find it with
`kubectl get pod -n <ns> --show-labels`.

> `TARGETS` and `RCLONE_PATH` use the `${VAR:?}` required syntax, so Coolify
> blocks the deploy (red border) until you set them.

## 3. Config files (Storages → File Mount)
Add two **File Mounts** and paste the contents — nothing is committed to git.
(Use File Mount, *not* a compose bind mount: Coolify creates file bind-mounts as
directories, coollabsio/coolify#8107.)

1. Destination `/config/kubeconfig` → contents of your `~/.kube/config`.
   ⚠️ The `server:` address must be reachable **from the Coolify host**. If it's
   `127.0.0.1`/`localhost`, replace it with the cluster's real IP/hostname.
2. Destination `/config/rclone.conf` → contents of your rclone config
   (run `rclone config file` to find its path).

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
- The kubeconfig user needs `pods/exec` rights in each target namespace.
- Every non-system database is dumped to its own file; add `EXCLUDE_DBS` (space-
  separated) to skip more.
- A per-DB app user only dumps what it has privileges on (events/routines need extra
  grants); if its dumps fail, use root for that target (drop the `/USER_VAR/PASS_VAR`
  suffix and rely on `PASSWORD_VAR`).
- Alternative to the built-in cron: drive backups from Coolify **Scheduled Tasks**
  (command `/usr/local/bin/backup.sh once`) for a manual "run now" button and run
  history in the UI. The container still runs its own cron either way.
