#!/usr/bin/env bash
# For each MySQL pod in TARGETS, dump EVERY (non-system) database to its OWN
# gzipped file under /backups, then rclone-copy the lot to a remote.
#
# Credentials never leave the cluster: mysql/mysqldump run INSIDE each pod and
# read the password from that pod's own env var (via MYSQL_PWD, so it never
# appears on the in-pod process list either).
set -euo pipefail

# --- config (with sensible defaults) ---
# TARGETS: whitespace/newline separated list, one entry per DB pod. Each entry:
#   namespace/selector                       -> user=root, password=$PASSWORD_VAR
#   namespace/selector/USER_VAR/PASS_VAR     -> user=$USER_VAR, password=$PASS_VAR
# "selector" is a label selector resolved to the running pod at backup time.
# USER_VAR/PASS_VAR are the names of env vars that exist INSIDE the pod.
TARGETS="${TARGETS:-}"
PASSWORD_VAR="${PASSWORD_VAR:-MYSQL_ROOT_PASSWORD}"  # default in-pod password var (root)
BACKUP_DIR="${BACKUP_DIR:-/backups}"
RCLONE_REMOTE="${RCLONE_REMOTE:-s3}"         # name of the remote in rclone.conf
RCLONE_PATH="${RCLONE_PATH:-my-bucket/mysql-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"        # delete local dumps older than this
EXCLUDE_DBS="${EXCLUDE_DBS:-}"               # extra databases to skip (space sep)
EXTRA_DUMP_FLAGS="${EXTRA_DUMP_FLAGS:-}"     # appended to mysqldump (e.g. --hex-blob)

# Schemas that can't / shouldn't be dumped as data. 'mysql' (grants/users) is
# skipped too — add it back via per-restore tooling if you really need it.
SYS_DBS="information_schema performance_schema sys mysql"

# Reliable, restore-friendly defaults:
#   --single-transaction --quick  -> consistent InnoDB snapshot, low memory
#   --routines --triggers --events -> stored programs travel with the schema
#   --no-tablespaces              -> no PROCESS privilege needed (restricted users)
#   --databases <db>              -> file recreates the DB (CREATE/USE headers)
DUMP_FLAGS="--single-transaction --quick --routines --triggers --events \
--no-tablespaces --default-character-set=utf8mb4"

log() { echo "[$(date '+%F %T')] $*"; }

if [ -z "${TARGETS// }" ]; then
  log "ERROR: TARGETS is empty. Set it to e.g. 'ns1/app=mysql ns2/app=mysql/MYSQL_USER/MYSQL_PASSWORD'"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
STAMP=$(date +%F-%H%M)
FAILED=0

# Build an ERE that matches any DB name we should skip.
skip_re="^($(echo "$SYS_DBS $EXCLUDE_DBS" | tr ' ' '\n' | grep -v '^$' | paste -sd'|' -))$"

for entry in $TARGETS; do
  IFS='/' read -r ns selector uservar passvar <<< "$entry"
  if [ -z "$ns" ] || [ -z "$selector" ]; then
    log "ERROR: bad TARGETS entry '$entry' (expected namespace/selector[/USER_VAR/PASS_VAR])"
    FAILED=1; continue
  fi

  # Credential expressions that expand INSIDE the pod (note the escaped $).
  if [ -n "${uservar:-}" ] && [ -n "${passvar:-}" ]; then
    user_flag="-u\"\$${uservar}\""; pw_env="\$${passvar}"; cred_label="${uservar}/${passvar}"
  else
    user_flag="-u root"; pw_env="\$${PASSWORD_VAR}"; cred_label="root/${PASSWORD_VAR}"
  fi

  # Resolve the current running pod from the label selector.
  pod=$(kubectl get pod -n "$ns" -l "$selector" \
          --field-selector=status.phase=Running \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$pod" ]; then
    log "ERROR: no running pod for selector '$selector' in namespace '$ns'"
    FAILED=1; continue
  fi
  safe_sel=$(echo "$selector" | tr -c 'A-Za-z0-9._-' '_')
  log "Target ${ns}/${pod} (selector '$selector', creds ${cred_label})"

  # 1) List databases from inside the pod.
  dbs=$(kubectl exec -n "$ns" "$pod" -- sh -c \
          "MYSQL_PWD=\"${pw_env}\" mysql ${user_flag} -N -B -e 'SHOW DATABASES'" \
          2>/dev/null || true)
  if [ -z "$dbs" ]; then
    log "ERROR: could not list databases on ${ns}/${pod} (check user/password vars)"
    FAILED=1; continue
  fi

  # 2) Dump each non-system database to its own file.
  dumped=0
  for db in $dbs; do
    echo "$db" | grep -Eq "$skip_re" && continue
    safe_db=$(echo "$db" | tr -c 'A-Za-z0-9._-' '_')
    outfile="$BACKUP_DIR/${ns}-${safe_sel}-${safe_db}-${STAMP}.sql.gz"
    log "  dump db '$db' -> $(basename "$outfile")"

    # pipefail (set above) makes a failed mysqldump fail the whole pipe.
    if kubectl exec -n "$ns" "$pod" -- sh -c \
          "MYSQL_PWD=\"${pw_env}\" mysqldump ${user_flag} ${DUMP_FLAGS} ${EXTRA_DUMP_FLAGS} --databases \"$db\"" \
          2>/dev/null | gzip > "$outfile" \
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
done

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
