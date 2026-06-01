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
# Each value is single-quoted (with embedded ' escaped) so values containing
# spaces -- multi-target TARGETS, multi-flag DUMP_FLAGS -- survive being sourced
# by cron's /bin/sh. Without quoting, `export TARGETS=a b c` breaks under cron.
: > /etc/backup.env
printenv | grep -E '^(TARGETS|BACKUP_DIR|RCLONE_REMOTE|RCLONE_PATH|RETENTION_DAYS|EXCLUDE_DBS|EXCLUDE_TABLES|DUMP_FLAGS|EXTRA_DUMP_FLAGS|DUMP_RETRIES|DUMP_BACKOFF|KUBECONFIG|RCLONE_CONFIG|TZ)=' \
  | while IFS='=' read -r name value; do
      esc=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
      printf "export %s='%s'\n" "$name" "$esc" >> /etc/backup.env
    done

cat > /etc/crontabs/root <<EOF
${CRON_SCHEDULE} . /etc/backup.env; /usr/local/bin/backup.sh >> /proc/1/fd/1 2>&1
EOF

log "Cron schedule installed: ${CRON_SCHEDULE}"
log "Container is up. Backups will run on schedule. (Use 'docker run ... once' to test now.)"

# -f foreground, -l 8 log level, -L /dev/stdout send cron logs to stdout
exec crond -f -l 8 -L /dev/stdout
