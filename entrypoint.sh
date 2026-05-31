#!/usr/bin/env bash
# Sets up a daily cron job and keeps the container alive running crond.
set -euo pipefail

# When to run. Default: every day at 02:00. Override with CRON_SCHEDULE.
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"

log() { echo "[$(date '+%F %T')] $*"; }

# Allow "run once and exit" mode for testing:  docker run ... once
if [ "${1:-}" = "once" ]; then
  log "Running a one-off backup now"
  exec /usr/local/bin/backup.sh
fi

# Build a crontab. We pass the current environment through to the job by
# dumping it into a file the job sources, since cron runs with a bare env.
printenv | grep -E '^(TARGETS|PASSWORD_VAR|BACKUP_DIR|RCLONE_REMOTE|RCLONE_PATH|RETENTION_DAYS|EXCLUDE_DBS|EXTRA_DUMP_FLAGS|KUBECONFIG|RCLONE_CONFIG|TZ)=' \
  | sed 's/^/export /' > /etc/backup.env

cat > /etc/crontabs/root <<EOF
${CRON_SCHEDULE} . /etc/backup.env; /usr/local/bin/backup.sh >> /proc/1/fd/1 2>&1
EOF

log "Cron schedule installed: ${CRON_SCHEDULE}"
log "Container is up. Backups will run on schedule. (Use 'docker run ... once' to test now.)"

# -f foreground, -l 8 log level, -L /dev/stdout send cron logs to stdout
exec crond -f -l 8 -L /dev/stdout
