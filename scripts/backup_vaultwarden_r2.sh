#!/usr/bin/env bash
# Vaultwarden -> Cloudflare R2 encrypted backup.
# Modelled on jarvis/scripts/backup_nocodb_r2.sh. See RESTORE.md for recovery.
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/vaultwarden/r2-backup.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing config file: $CONFIG_FILE" >&2
  exit 2
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${VW_DATA_DIR:?Set VW_DATA_DIR}"
: "${BACKUP_WORK_DIR:?Set BACKUP_WORK_DIR}"
: "${RCLONE_REMOTE:?Set RCLONE_REMOTE}"
: "${RCLONE_DEST:?Set RCLONE_DEST}"
: "${GPG_PASSPHRASE_FILE:?Set GPG_PASSPHRASE_FILE}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE_DIR="$BACKUP_WORK_DIR/archives"
TMP_DIR="$BACKUP_WORK_DIR/tmp-$TIMESTAMP"
ENCRYPTED="$ARCHIVE_DIR/vaultwarden-$TIMESTAMP.tar.gz.gpg"

umask 077
mkdir -p "$ARCHIVE_DIR" "$TMP_DIR/vaultwarden"

STAGE="startup"
FAILED_COMMAND=""
FAILED_LINE=""

stage() {
  STAGE="$1"
  echo "[$(date -Is)] $1"
}

on_err() {
  FAILED_COMMAND="$BASH_COMMAND"
  FAILED_LINE="$1"
}
trap 'on_err "$LINENO"' ERR

notify_discord() {
  [[ -n "${DISCORD_WEBHOOK_URL:-}" ]] || return 0
  local payload
  payload=$(printf '%s' "$1" | "$PYTHON_BIN" -c 'import json,sys; print(json.dumps({"content": sys.stdin.read()}))') || return 0
  curl -sS -m 15 -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || echo "[$(date -Is)] WARNING: could not post Discord notification" >&2
}

cleanup() {
  local status=$?
  trap - ERR
  # TMP_DIR holds a plaintext copy of the vault DB and RSA key.
  rm -rf "$TMP_DIR"
  if (( status != 0 )); then
    local cmd="${FAILED_COMMAND:-unknown}"
    if (( ${#cmd} > 200 )); then cmd="${cmd:0:200}..."; fi
    notify_discord "**Vaultwarden backup FAILED**
host: $(hostname)
time: $(date -Is)
exit: $status
stage: $STAGE
line: ${FAILED_LINE:-?}
command: $cmd"
  elif [[ "${NOTIFY_ON_SUCCESS:-0}" == "1" ]]; then
    notify_discord "Vaultwarden backup ok - host: $(hostname), time: $(date -Is)"
  fi
  return $status
}
trap cleanup EXIT

# Online backup API gives a consistent copy that includes un-checkpointed WAL
# pages; copying db.sqlite3 by itself would miss recent changes.
stage "Creating SQLite snapshot"
"$PYTHON_BIN" - "$VW_DATA_DIR/db.sqlite3" "$TMP_DIR/vaultwarden/db.sqlite3" <<'PY'
import sqlite3
import sys

source_path, dest_path = sys.argv[1], sys.argv[2]
source = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True)
try:
    dest = sqlite3.connect(dest_path)
    try:
        source.backup(dest)
        result = dest.execute("PRAGMA integrity_check").fetchone()
        if not result or result[0] != "ok":
            raise SystemExit(f"SQLite integrity check failed: {result}")
        users = dest.execute("SELECT count(*) FROM users").fetchone()[0]
        if users == 0:
            raise SystemExit("Snapshot has no users - refusing to upload")
    finally:
        dest.close()
finally:
    source.close()
PY

stage "Copying keys, attachments and config"
# rsa_key*.pem signs login tokens; attachments/ and sends/ hold encrypted files.
# icon_cache/ and tmp/ are regenerated, so they are skipped.
for item in rsa_key.pem rsa_key.pub.pem config.json attachments sends; do
  if [[ -e "$VW_DATA_DIR/$item" ]]; then
    cp -a "$VW_DATA_DIR/$item" "$TMP_DIR/vaultwarden/"
  fi
done
if [[ -n "${COMPOSE_FILE_PATH:-}" && -f "$COMPOSE_FILE_PATH" ]]; then
  cp "$COMPOSE_FILE_PATH" "$TMP_DIR/vaultwarden/docker-compose.yml"
fi

stage "Building and encrypting archive: $ENCRYPTED"
tar -C "$TMP_DIR" -czf - vaultwarden \
  | gpg --batch --yes --symmetric --cipher-algo AES256 \
      --passphrase-file "$GPG_PASSPHRASE_FILE" \
      --output "$ENCRYPTED"

stage "Uploading to R2: $RCLONE_REMOTE:$RCLONE_DEST"
rclone copy "$ENCRYPTED" "$RCLONE_REMOTE:$RCLONE_DEST"

stage "Pruning local backup files"
find "$ARCHIVE_DIR" -type f -name 'vaultwarden-*.tar.gz.gpg' -mtime +"${LOCAL_KEEP_DAYS:-3}" -delete

if [[ "${REMOTE_PRUNE:-0}" == "1" ]]; then
  stage "Pruning remote archives older than ${REMOTE_KEEP_DAYS:-30} days"
  rclone delete "$RCLONE_REMOTE:$RCLONE_DEST" \
    --min-age "${REMOTE_KEEP_DAYS:-30}d" \
    --include 'vaultwarden-*.tar.gz.gpg'
fi

stage "Backup completed: $(basename "$ENCRYPTED")"
