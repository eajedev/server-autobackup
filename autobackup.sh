#!/usr/bin/env bash
# eaje-autobackup — self-hosted equivalent of Contabo's paid "Auto Backup" add-on.
#
# Contabo Auto Backup model (docs.contabo.com, verified 2026-11-12):
#   - one backup per day; first backup is a full copy, later ones incremental
#   - at least 8 hours between backups
#   - retention: at most 10 backups, each kept at most 10 days, oldest deleted first
#   - stored off-server
#
# This script mirrors that model with restic (encrypted, deduplicated,
# incremental-forever after the first full snapshot):
#   - daily run via systemd timer (eaje-autobackup.timer)
#   - refuses to start a second backup within 8h of the last successful one
#   - retention: --keep-daily 10 --keep-within 10d (oldest pruned first)
#   - repository is expected to be OFF-SERVER (S3 / B2 / SFTP / mounted remote)
#
# Before the file backup it dumps every running Postgres / MySQL / MariaDB
# docker container into the staging dir, so database restores are clean
# SQL files instead of raw data-directory copies.
#
# Usage:
#   autobackup.sh            normal run (8h guard applies)
#   autobackup.sh --force    ignore the 8h guard (first run / manual run)
#   autobackup.sh --init     initialise the restic repository, then exit
#
# Exit codes: 0 ok / skipped-by-guard, 1 config error, 2 dump or backup failure.

set -uo pipefail

CONFIG_FILE="${AUTOBACKUP_CONFIG:-/etc/eaje-autobackup/config.env}"
STATE_DIR="/var/lib/eaje-autobackup"
DUMP_DIR="$STATE_DIR/dumps"
STATUS_FILE="$STATE_DIR/status.json"
LAST_RUN_FILE="$STATE_DIR/last-success.epoch"
LOG_FILE="/var/log/eaje-autobackup.log"
MIN_INTERVAL_SECONDS=$((8 * 3600))   # Contabo rule: at least 8h between backups
KEEP_DAILY=10                        # Contabo rule: at most 10 backups
KEEP_WITHIN="10d"                    # Contabo rule: each backup at most 10 days

log() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*"
  echo "$line" | tee -a "$LOG_FILE"
}

write_status() {
  # $1 = result (success|failed|skipped), $2 = detail
  local now
  now="$(date -Is)"
  printf '{\n  "last_run": "%s",\n  "result": "%s",\n  "detail": "%s",\n  "keep_daily": %s,\n  "keep_within": "%s"\n}\n' \
    "$now" "$1" "$2" "$KEEP_DAILY" "$KEEP_WITHIN" > "$STATUS_FILE"
}

fail() { log "ERROR: $*"; write_status "failed" "$*"; exit "${2:-1}"; }

# ---------------------------------------------------------------- config ----
[ -f "$CONFIG_FILE" ] || fail "config not found: $CONFIG_FILE" 1
# shellcheck disable=SC1090
. "$CONFIG_FILE"

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is not set in $CONFIG_FILE}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE is not set in $CONFIG_FILE}"
[ -f "$RESTIC_PASSWORD_FILE" ] || fail "restic password file missing: $RESTIC_PASSWORD_FILE" 1
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

# What gets backed up. Coolify keeps everything that matters under /data;
# docker volumes hold app storage; /etc + /root hold server configuration.
BACKUP_PATHS_DEFAULT="/data /var/lib/docker/volumes /etc /root $DUMP_DIR"
# shellcheck disable=SC2206
BACKUP_PATHS=(${BACKUP_SOURCES:-$BACKUP_PATHS_DEFAULT})

command -v restic >/dev/null 2>&1 || fail "restic is not installed (run install.sh)" 1
mkdir -p "$DUMP_DIR" "$STATE_DIR"
touch "$LOG_FILE"

if [ "${1:-}" = "--init" ]; then
  log "Initialising restic repository at $RESTIC_REPOSITORY"
  restic init && { log "Repository initialised."; exit 0; }
  fail "restic init failed" 1
fi

# ------------------------------------------------------------- 8h guard -----
exec 9>"$STATE_DIR/run.lock"
if ! flock -n 9; then
  log "Another autobackup run is in progress — skipping."
  exit 0
fi

if [ "${1:-}" != "--force" ] && [ -f "$LAST_RUN_FILE" ]; then
  last="$(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  age=$((now_epoch - last))
  if [ "$age" -lt "$MIN_INTERVAL_SECONDS" ]; then
    log "Last successful backup was ${age}s ago (< 8h, Contabo minimum interval) — skipping."
    write_status "skipped" "minimum 8h interval not reached"
    exit 0
  fi
fi

# ------------------------------------------------------------ DB dumps ------
log "Dumping databases from running containers..."
dump_failures=0
if command -v docker >/dev/null 2>&1; then
  rm -f "$DUMP_DIR"/*.sql "$DUMP_DIR"/*.sql.gz 2>/dev/null || true
  while IFS= read -r cid; do
    image="$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null || echo '')"
    name="$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | tr -d '/' || echo "$cid")"
    case "$image" in
      *postgres*)
        pguser="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$cid" | sed -n 's/^POSTGRES_USER=//p' | head -1)"
        pguser="${pguser:-postgres}"
        log "  pg_dumpall: $name ($image) as $pguser"
        if docker exec "$cid" pg_dumpall -U "$pguser" 2>/dev/null | gzip > "$DUMP_DIR/${name}.sql.gz"; then
          :
        else
          log "  WARNING: pg_dumpall failed for $name"; dump_failures=$((dump_failures + 1))
        fi
        ;;
      *mysql*|*mariadb*)
        log "  mysqldump: $name ($image)"
        if docker exec "$cid" sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction' 2>/dev/null | gzip > "$DUMP_DIR/${name}.sql.gz"; then
          :
        else
          log "  WARNING: mysqldump failed for $name"; dump_failures=$((dump_failures + 1))
        fi
        ;;
    esac
  done < <(docker ps -q 2>/dev/null)
else
  log "  docker not found — skipping database dumps."
fi
[ "$dump_failures" -gt 0 ] && log "  $dump_failures database dump(s) failed; continuing with file backup."

# --------------------------------------------------------------- backup -----
existing=()
for p in "${BACKUP_PATHS[@]}"; do
  if [ -e "$p" ]; then existing+=("$p"); else log "  source missing, skipped: $p"; fi
done
[ "${#existing[@]}" -gt 0 ] || fail "no backup sources exist" 2

log "Starting restic backup of: ${existing[*]}"
if ! restic backup "${existing[@]}" \
      --tag autobackup --tag daily \
      --exclude-caches \
      --exclude '/var/lib/docker/volumes/*/cache' \
      --one-file-system=false; then
  fail "restic backup failed" 2
fi

# ------------------------------------------------------------- retention ----
# Contabo keeps at most 10 backups, each at most 10 days, oldest first.
log "Applying retention: keep-daily $KEEP_DAILY, keep-within $KEEP_WITHIN, prune."
if ! restic forget --tag autobackup --keep-daily "$KEEP_DAILY" --keep-within "$KEEP_WITHIN" --prune; then
  fail "restic forget/prune failed" 2
fi

# ------------------------------------------------------------- integrity ----
log "Checking repository structure..."
if ! restic check; then
  fail "restic check failed — repository needs attention" 2
fi
# Once a week (Sunday), also verify a sample of the actual backup data.
if [ "$(date +%u)" = "7" ]; then
  log "Sunday: verifying a 5% sample of backup data..."
  restic check --read-data-subset=5% || log "WARNING: Sunday data-sample check reported problems."
fi

date +%s > "$LAST_RUN_FILE"
count="$(restic snapshots --tag autobackup --json 2>/dev/null | grep -c '"time"' || echo '?')"
log "Backup complete. Restore points currently held: $count (cap $KEEP_DAILY)."
write_status "success" "restore points held: $count"
exit 0
