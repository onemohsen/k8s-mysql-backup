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
EXCLUDE_TABLES="${EXCLUDE_TABLES:-}"         # per-DB tables to skip entirely (bare
                                             # names, space sep; e.g. telescope_entries)
EXTRA_DUMP_FLAGS="${EXTRA_DUMP_FLAGS:-}"     # appended to mysqldump
DUMP_RETRIES="${DUMP_RETRIES:-3}"            # attempts per DB on transient failure
DUMP_BACKOFF="${DUMP_BACKOFF:-15}"           # base backoff seconds between retries

# Schemas that can't / shouldn't be dumped as data. 'mysql' (grants/users) too.
SYS_DBS="information_schema performance_schema sys mysql"

# Reliable, restore-friendly defaults (override the whole set with DUMP_FLAGS):
#   --single-transaction --quick  -> consistent InnoDB snapshot, low memory
#   --routines --triggers --events -> stored programs travel with the schema
#   --no-tablespaces              -> no PROCESS privilege needed (restricted users)
#   --max-allowed-packet=1G       -> don't abort on huge rows (e.g. Laravel
#                                    Telescope JSON); default 24M can truncate
#   --set-gtid-purged=OFF         -> portable restore into an existing/GTID server
#   --databases <db>              -> file recreates the DB (CREATE/USE headers)
# NB: do NOT add --compact / --skip-comments here — the dump's trailing
#     "-- Dump completed" line is our completeness marker (see dump_one_db).
DUMP_FLAGS="${DUMP_FLAGS:-"--single-transaction --quick --routines --triggers \
--events --no-tablespaces --default-character-set=utf8mb4 \
--max-allowed-packet=1G --set-gtid-purged=OFF"}"

log() { echo "[$(date '+%F %T')] $*"; }

# Run a mysql/mysqldump invocation INSIDE the pod, password supplied via stdin.
# Usage: pod_mysql NS POD PASSWORD <binary> [args...]   (output -> stdout)
pod_mysql() {
  local ns="$1" pod="$2" pass="$3"; shift 3
  printf '%s\n' "$pass" | kubectl exec -i -n "$ns" "$pod" -- sh -c \
    'IFS= read -r MYSQL_PWD; export MYSQL_PWD; exec "$@"' _ "$@"
}

# Dump ONE database to a gzipped file, verified, with retries.
# WHY: a streamed mysqldump can be SILENTLY TRUNCATED -- kubectl exec can return 0
# on a dropped stream, and gzip then wraps the partial output into a *valid* .gz.
# So `gzip -t` and a size floor are NOT enough. We verify three independent things:
#   1. mysqldump's OWN exit status (PIPESTATUS[0], not gzip's),
#   2. the gzip frame is intact (gzip -t),
#   3. the in-band "-- Dump completed" footer mysqldump writes LAST on success.
# Only all three together prove the dump arrived whole.
# Usage: dump_one_db NS POD PASS USER DB OUTFILE [extra mysqldump args...]
dump_one_db() {
  local ns="$1" pod="$2" pass="$3" user="$4" db="$5" outfile="$6"; shift 6
  local attempt=1 rc errfile
  errfile="$(mktemp)"

  while [ "$attempt" -le "$DUMP_RETRIES" ]; do
    rm -f "$outfile"

    # Capture mysqldump's real status: temporarily drop errexit so the pipeline
    # can't abort the script before we read PIPESTATUS. stderr -> errfile so a
    # "Lost connection ... when dumping table X" is logged, not swallowed.
    set +e
    pod_mysql "$ns" "$pod" "$pass" \
        mysqldump -u"$user" $DUMP_FLAGS $EXTRA_DUMP_FLAGS "$@" --databases "$db" 2>"$errfile" \
      | gzip > "$outfile"
    rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" -eq 0 ] \
       && gzip -t "$outfile" 2>/dev/null \
       && [ "$(stat -c%s "$outfile")" -ge 1024 ] \
       && gzip -dc "$outfile" 2>/dev/null | tail -n 5 | grep -q -- '-- Dump completed'; then
      rm -f "$errfile"
      return 0
    fi

    log "    attempt ${attempt}/${DUMP_RETRIES} failed for '$db' (mysqldump rc=$rc)"
    [ -s "$errfile" ] && log "    mysqldump: $(tr '\n' '|' < "$errfile" | cut -c1-300)"
    attempt=$((attempt + 1))
    [ "$attempt" -le "$DUMP_RETRIES" ] && sleep $((DUMP_BACKOFF * (attempt - 1)))
  done

  rm -f "$outfile" "$errfile"   # never leave a truncated dump behind
  return 1
}

if [ -z "${TARGETS// }" ]; then
  log "ERROR: TARGETS is empty. Set it to e.g. 'ns/pod/user/password ns2/pod2/user2/pw2'"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
STAMP=$(date +%F-%H%M%S)
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

    # Per-DB --ignore-table flags from EXCLUDE_TABLES (qualified to this db).
    ignore_flags=""
    for t in $EXCLUDE_TABLES; do
      ignore_flags="$ignore_flags --ignore-table=${db}.${t}"
    done

    log "  dump db '$db' -> $(basename "$outfile")"
    if dump_one_db "$ns" "$pod" "$pass" "$user" "$db" "$outfile" $ignore_flags; then
      log "  OK: $db ($(du -h "$outfile" | cut -f1))"
      dumped=$((dumped + 1))
    else
      log "  ERROR: dump failed/truncated for db '$db' on ${ns}/${pod} after ${DUMP_RETRIES} tries"
      FAILED=1
    fi
  done
  [ "$dumped" -eq 0 ] && { log "WARNING: no databases dumped for ${ns}/${pod}"; FAILED=1; }
  set -f
done
set +f

log "Uploading $BACKUP_DIR -> ${RCLONE_REMOTE}:${RCLONE_PATH}"
# --checksum: compare by hash, not size+mtime. --stats*: cron-safe line logging
# (no --progress; it spews ANSI carriage-returns into a non-TTY cron log).
upload_ok=0
if rclone copy "$BACKUP_DIR" "${RCLONE_REMOTE}:${RCLONE_PATH}" \
     --checksum --stats=30s --stats-one-line -v; then
  log "Upload complete"
  upload_ok=1
else
  log "ERROR: rclone upload failed"
  FAILED=1
fi

# Prune ONLY after a clean run that uploaded successfully, so a streak of failed
# runs can never age out the last good local copy (the remote may not have one).
if [ "$FAILED" -eq 0 ] && [ "$upload_ok" -eq 1 ]; then
  log "Pruning local dumps older than ${RETENTION_DAYS} days"
  find "$BACKUP_DIR" -name '*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete
else
  log "Skipping prune (run had failures or upload failed) — keeping existing local dumps"
fi

if [ "$FAILED" -ne 0 ]; then
  log "Finished WITH ERRORS"
  exit 1
fi
log "Finished successfully"
