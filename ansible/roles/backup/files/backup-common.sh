# Settings and container handling shared by the backup and restore scripts.
set -a
# shellcheck disable=SC1091
. /etc/homeserver/backup.env
set +a
# shellcheck disable=SC1091
. /etc/homeserver/backup.conf

SNAPSHOT_TAG=homeserver
BACKUP_MARKER=/var/lib/homeserver/backup-enabled
STOPPED_RECORD=/var/lib/homeserver/stopped-apps
RECORD_STOPPED_APPS=false
STOPPED_APPS=()

lock_backup_data() {
  exec 9>/run/homeserver-backup.lock
  flock -n 9 || { echo "another backup or restore is running" >&2; exit 1; }
}

stop_data_apps() {
  local app dir running
  for app in "${DATA_APPS[@]}"; do
    dir="$APPS_DIR/$app"
    [ -f "$dir/compose.yaml" ] || continue
    running="$(docker compose --project-directory "$dir" ps --status running -q)"
    [ -n "$running" ] || continue
    STOPPED_APPS+=("$app")
    [ "$RECORD_STOPPED_APPS" = false ] || echo "$app" >>"$STOPPED_RECORD"
    docker compose --project-directory "$dir" stop
  done
}

start_stopped_apps() {
  local app failed=0
  for app in "${STOPPED_APPS[@]}"; do
    docker compose --project-directory "$APPS_DIR/$app" start || failed=1
  done
  STOPPED_APPS=()
  if [ "$failed" -eq 0 ] && [ "$RECORD_STOPPED_APPS" = true ]; then
    rm -f "$STOPPED_RECORD"
  fi
  return "$failed"
}

# Docker keeps a stopped container stopped across reboots, so a killed backup has to be undone explicitly.
recover_interrupted_apps() {
  [ -f "$STOPPED_RECORD" ] || return 0
  local app failed=0
  while read -r app; do
    docker compose --project-directory "$APPS_DIR/$app" start || failed=1
  done <"$STOPPED_RECORD"
  [ "$failed" -eq 0 ] && rm -f "$STOPPED_RECORD"
}
