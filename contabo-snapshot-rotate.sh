#!/usr/bin/env bash
# contabo-snapshot-rotate — OPTIONAL second layer: true disk-image snapshots
# through Contabo's own API, using the snapshot slots already included in
# the VPS plan (Cloud VPS 12 includes 3).
#
# Why this is only a bonus layer: the plan's slots cap us at 3 restore
# points, while the Auto Backup model holds 10 — the daily restic engine
# in autobackup.sh carries the 10-point retention. These snapshots add the
# one thing restic cannot do: a one-click, whole-disk rollback at Contabo.
#
# Safety rules baked in:
#   - Only snapshots named autobackup-* are ever deleted. Manual snapshots
#     are never touched.
#   - Nothing is deleted unless the new snapshot was created successfully.
#   - If all slots are taken by snapshots we do not own, the script exits
#     with an error instead of deleting anything.
#
# Credentials live in /etc/eaje-autobackup/contabo-api.env (chmod 600):
#   CONTABO_CLIENT_ID, CONTABO_CLIENT_SECRET,
#   CONTABO_API_USER (panel email), CONTABO_API_PASSWORD
# Create them in the Contabo panel under API access. Never commit them.
#
# Run weekly (see README) or by hand. Suggested: Sunday 04:30.
#
# API reference: https://api.contabo.com — endpoints below follow the v1
# compute API. If Contabo changes the API, this script fails safe (it
# stops; it does not improvise deletions).

set -uo pipefail

ENV_FILE="${CONTABO_API_ENV:-/etc/eaje-autobackup/contabo-api.env}"
KEEP="${SNAPSHOT_KEEP:-3}"          # plan-included slots on Cloud VPS 12
PREFIX="autobackup-"
LOG_FILE="/var/log/eaje-autobackup.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] [snapshot] $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

[ -f "$ENV_FILE" ] || die "API credentials file missing: $ENV_FILE"
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${CONTABO_CLIENT_ID:?}" "${CONTABO_CLIENT_SECRET:?}" "${CONTABO_API_USER:?}" "${CONTABO_API_PASSWORD:?}"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v curl >/dev/null 2>&1 || die "curl is required"

req_id() { cat /proc/sys/kernel/random/uuid; }

# ------------------------------------------------------------ get token -----
TOKEN="$(curl -s -X POST 'https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=password' \
  --data-urlencode "client_id=$CONTABO_CLIENT_ID" \
  --data-urlencode "client_secret=$CONTABO_CLIENT_SECRET" \
  --data-urlencode "username=$CONTABO_API_USER" \
  --data-urlencode "password=$CONTABO_API_PASSWORD" | jq -r '.access_token // empty')"
[ -n "$TOKEN" ] || die "could not obtain Contabo API token (check credentials in $ENV_FILE)"

api() { # $1 method, $2 path, $3 optional json body
  local args=(-s -X "$1" "https://api.contabo.com$2"
              -H "Authorization: Bearer $TOKEN"
              -H "x-request-id: $(req_id)")
  [ -n "${3:-}" ] && args+=(-H 'Content-Type: application/json' -d "$3")
  curl "${args[@]}"
}

# --------------------------------------------------------- find instance ----
INSTANCES="$(api GET '/v1/compute/instances')"
INSTANCE_ID="$(echo "$INSTANCES" | jq -r '.data[0].instanceId // empty')"
[ -n "$INSTANCE_ID" ] || die "no VPS instance found on this Contabo account"
log "Instance: $INSTANCE_ID"

# --------------------------------------------------------- create snapshot --
NAME="${PREFIX}$(date +%Y%m%d-%H%M)"
CREATE="$(api POST "/v1/compute/instances/$INSTANCE_ID/snapshots" \
  "{\"name\": \"$NAME\", \"description\": \"Eaje Autobackup weekly disk snapshot\"}")"
echo "$CREATE" | jq -e '.data[0].snapshotId' >/dev/null 2>&1 \
  || die "snapshot creation failed (slots may be full with snapshots we do not manage): $CREATE"
log "Created snapshot $NAME"

# -------------------------------------------------------------- rotate ------
SNAPS="$(api GET "/v1/compute/instances/$INSTANCE_ID/snapshots")"
# Our snapshots, oldest first.
mapfile -t OURS < <(echo "$SNAPS" | jq -r --arg p "$PREFIX" \
  '.data | map(select(.name | startswith($p))) | sort_by(.createdDate) | .[].snapshotId')
total="${#OURS[@]}"
log "autobackup snapshots held: $total (keep $KEEP)"
if [ "$total" -gt "$KEEP" ]; then
  remove=$((total - KEEP))
  for ((i = 0; i < remove; i++)); do
    log "Deleting oldest autobackup snapshot ${OURS[$i]}"
    api DELETE "/v1/compute/instances/$INSTANCE_ID/snapshots/${OURS[$i]}" >/dev/null
  done
fi
log "Snapshot rotation complete."
exit 0
