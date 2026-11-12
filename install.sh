#!/usr/bin/env bash
# install.sh — install Eaje Autobackup on the VPS (Ubuntu/Debian, root).
#
# What it does:
#   1. installs restic + jq if missing
#   2. creates /etc/eaje-autobackup (config + repo password, root-only)
#   3. installs the backup script and the systemd service + daily timer
#   4. enables the timer
# It does NOT start a backup and does NOT initialise the repository until
# you have set RESTIC_REPOSITORY in the config (see README, step 2).

set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "Run as root."; exit 1; }
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG_DIR="/etc/eaje-autobackup"
STATE_DIR="/var/lib/eaje-autobackup"

echo "==> Installing packages (restic, jq) if needed"
if ! command -v restic >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq restic jq
fi

echo "==> Creating directories"
install -d -m 700 "$CFG_DIR" "$STATE_DIR" "$STATE_DIR/dumps"

echo "==> Installing script"
install -m 750 "$SRC_DIR/autobackup.sh" /usr/local/bin/eaje-autobackup.sh
if [ -f "$SRC_DIR/contabo-snapshot-rotate.sh" ]; then
  install -m 750 "$SRC_DIR/contabo-snapshot-rotate.sh" /usr/local/bin/contabo-snapshot-rotate.sh
fi

echo "==> Config"
if [ ! -f "$CFG_DIR/config.env" ]; then
  install -m 600 "$SRC_DIR/config.env.example" "$CFG_DIR/config.env"
  echo "    Created $CFG_DIR/config.env — EDIT IT: set RESTIC_REPOSITORY."
else
  echo "    Existing config kept."
fi
if [ ! -f "$CFG_DIR/repo-password" ]; then
  openssl rand -base64 32 > "$CFG_DIR/repo-password"
  chmod 600 "$CFG_DIR/repo-password"
  echo "    Generated restic repository password at $CFG_DIR/repo-password"
  echo "    !!! Copy this password somewhere OFF this server. Without it,"
  echo "    !!! the backups can never be restored."
fi
if [ ! -f "$CFG_DIR/contabo-api.env" ] && [ -f "$SRC_DIR/contabo-api.env.example" ]; then
  install -m 600 "$SRC_DIR/contabo-api.env.example" "$CFG_DIR/contabo-api.env"
  echo "    Created empty $CFG_DIR/contabo-api.env (only needed for the optional snapshot layer)."
fi

echo "==> Installing systemd units"
install -m 644 "$SRC_DIR/eaje-autobackup.service" /etc/systemd/system/eaje-autobackup.service
install -m 644 "$SRC_DIR/eaje-autobackup.timer" /etc/systemd/system/eaje-autobackup.timer
systemctl daemon-reload
systemctl enable --now eaje-autobackup.timer

echo
echo "Installed. Next steps:"
echo "  1. Edit $CFG_DIR/config.env and set RESTIC_REPOSITORY (+ S3 keys if used)."
echo "  2. Initialise the repository:  eaje-autobackup.sh --init"
echo "  3. First (full) backup:        eaje-autobackup.sh --force"
echo "  4. Check the timer:            systemctl list-timers eaje-autobackup.timer"
echo "  5. Status of last run:         cat $STATE_DIR/status.json"
