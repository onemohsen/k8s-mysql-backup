#!/usr/bin/env bash
# For each MySQL pod in TARGETS, dump EVERY (non-system) database to its OWN
# gzipped file under /backups, then rclone-copy the lot to a remote.
#
# Each TARGETS entry is "namespace/pod/user/password" (literal credentials).
# The password is fed to mysql/mysqldump INSIDE the pod via stdin, so it never
# appears on a process list and special characters can't be re-parsed by a shell.
set -euo pipefail

# --- config (with sensible defaults) ---
# TARGETS: whitespace-separated entries, one per DB pod:
#   namespace/pod/user/password
# The password is everything after the 3rd "/", so it may itself contain "/".
TARGETS="${TARGETS:-}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
RCLONE_REMOTE="${RCLONE_REMOTE:-s3}"         # name of the remote in rclone.conf
RCLONE_PATH="${RCLONE_PATH:-my-bucket/mysql-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"        # delete local dumps older than this
EXCLUDE_DBS="${EXCLUDE_DBS:-}"               # extra databases to skip (space sep)
EXTRA_DUMP_FLAGS="${EXTRA_DUMP_FLAGS:-}"     # appended to mysqldump

# Schemas that can't / shouldn't be dumped as data. 'mysql' (grants/users) too.
SYS_DBS="information_schema performance_schema sys mysql"

# Reliable, restore-friendly defaults (override the whole set with DUMP_FLAGS):
#   --single-transaction --quick  -> consistent InnoDB snapshot, low memory
#   --routines --triggers --events -> stored programs travel with the schema
#   --no-tablespaces              -> no PROCESS privilege needed (restricted users)
#   --databases <db>              -> file recreates the DB (CREATE/USE headers)
DUMP_FLAGS="${DUMP_FLAGS:-"--single-transaction --quick --routines --triggers \
--events --no-tablespaces --default-character-set=utf8mb4"}"

log() { echo "[$(date '+%F %T')] $*"; }

# Run a mysql/mysqldump invocation INSIDE the pod, password supplied via stdin.
# Usage: pod_mysql NS POD PASSWORD <binary> [args...]   (output -> stdout)
pod_mysql() {
  local ns="$1" pod="$2" pass="$3"; shift 3
  printf '%s\n' "$pass" | kubectl exec -i -n "$ns" "$pod" -- sh -c \
    'IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec "$@"' _ "$@"
}

if [ -z "${TARGETS// }" ]; then
  log "ERROR: TARGETS is empty. Set it to e.g. 'ns/pod/user/password ns2/pod2/user2/pw2'"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
STAMP=$(date +%F-%H%M)
FAILED=0

# Build an ERE matching any DB name to skip.
skip_re="^($(echo "$SYS_DBS $EXCLUDE_DBS" | tr ' ' '\n' | grep -v '^$' | paste -sd'|' -))$"

set -f  # no globbing while splitting TARGETS (passwords may contain * ? [ )
for entry in $TARGETS; do
  set +f
  # Split on '/': ns, pod, user, then password = remainder (may contain '/').
  IFS='/' read -r ns pod user pass <<< "$entry"
  if [ -z "$ns" ] || [ -z "$pod" ] || [ -z "$user" ] || [ -z "$pass" ]; then
    log "ERROR: bad TARGETS entry '${ns:-?}/${pod:-?}/...' (need namespace/pod/user/password)"
    FAILED=1; set -f; continue
  fi

  if ! kubectl get pod -n "$ns" "$pod" >/dev/null 2>&1; then
    log "ERROR: pod '$pod' not found in namespace '$ns'"
    FAILED=1; set -f; continue
  fi
  log "Target ${ns}/${pod} (user '${user}')"

  # 1) List databases from inside the pod.
  dbs=$(pod_mysql "$ns" "$pod" "$pass" mysql -u"$user" -N -B -e 'SHOW DATABASES' 2>/dev/null || true)
  if [ -z "$dbs" ]; then
    log "ERROR: could not list databases on ${ns}/${pod} (check user/password)"
    FAILED=1; set -f; continue
  fi

  # 2) Dump each non-system database to its own file.
  dumped=0
  for db in $dbs; do
    echo "$db" | grep -Eq "$skip_re" && continue
    safe_db=$(echo "$db" | tr -c 'A-Za-z0-9._-' '_')
    outfile="$BACKUP_DIR/${ns}-${pod}-${safe_db}-${STAMP}.sql.gz"
    log "  dump db '$db' -> $(basename "$outfile")"

    if pod_mysql "$ns" "$pod" "$pass" \
          mysqldump -u"$user" $DUMP_FLAGS $EXTRA_DUMP_FLAGS --databases "$db" 2>/dev/null \
         | gzip > "$outfile" \
       && gzip -t "$outfile" 2>/dev/null \
       && [ "$(stat -c%s "$outfile")" -ge 1024 ]; then
      log "  OK: $db ($(du -h "$outfile" | cut -f1))"
      dumped=$((dumped + 1))
    else
      log "  ERROR: dump failed or too small for db '$db' on ${ns}/${pod}"
      rm -f "$outfile"
      FAILED=1
    fi
  done
  [ "$dumped" -eq 0 ] && { log "WARNING: no databases dumped for ${ns}/${pod}"; FAILED=1; }
  set -f
done
set +f

log "Uploading $BACKUP_DIR -> ${RCLONE_REMOTE}:${RCLONE_PATH}"
if rclone copy "$BACKUP_DIR" "${RCLONE_REMOTE}:${RCLONE_PATH}" --progress; then
  log "Upload complete"
else
  log "ERROR: rclone upload failed"
  FAILED=1
fi

log "Pruning local dumps older than ${RETENTION_DAYS} days"
find "$BACKUP_DIR" -name '*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete

if [ "$FAILED" -ne 0 ]; then
  log "Finished WITH ERRORS"
  exit 1
fi
log "Finished successfully"
