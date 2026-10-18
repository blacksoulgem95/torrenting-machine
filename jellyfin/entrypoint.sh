#!/bin/bash
# Monta in sola lettura la libreria B2 su /media e avvia Jellyfin.
# Le credenziali arrivano al boot come env (fly secrets): B2_KEY_ID, B2_APP_KEY,
# B2_CRYPT_PASSWORD/B2_CRYPT_PASSWORD2 (le stesse della seedbox).
# Se rclone o Jellyfin terminano, il container esce e Fly riavvia la macchina.
set -euo pipefail

MEDIA=/media
CACHE_DIR=/config/rclone-cache
RCLONE_CONF=/root/.config/rclone/rclone.conf

log() { echo "[entrypoint] $*"; }

for v in B2_KEY_ID B2_APP_KEY B2_BUCKET B2_ENDPOINT B2_REGION \
	B2_CRYPT_PASSWORD B2_CRYPT_PASSWORD2; do
	if [ -z "${!v:-}" ]; then
		log "variabile $v mancante (secrets: fly secrets set $v=...)" >&2
		exit 1
	fi
done

mkdir -p "$(dirname "$RCLONE_CONF")" "$MEDIA" "$CACHE_DIR" \
	"${JELLYFIN_DATA_DIR:-/config/data}" "${JELLYFIN_CACHE_DIR:-/config/cache}"
(umask 077; cat > "$RCLONE_CONF" <<EOF
[b2]
type = s3
provider = Other
access_key_id = $B2_KEY_ID
secret_access_key = $B2_APP_KEY
endpoint = https://${B2_ENDPOINT#https://}
region = $B2_REGION

[b2crypt]
type = crypt
remote = b2:$B2_BUCKET/${B2_PATH:-}
filename_encryption = standard
directory_name_encryption = true
password = $(printf %s "$B2_CRYPT_PASSWORD" | rclone obscure -)
password2 = $(printf %s "$B2_CRYPT_PASSWORD2" | rclone obscure -)
EOF
)

# dopo un riavvio può restare un mount orfano
fusermount3 -uz "$MEDIA" 2>/dev/null || true

log "mount b2crypt:${B2_CRYPT_SUBDIR:-} (b2:$B2_BUCKET/${B2_PATH:-}, cifrato) su $MEDIA"
rclone mount "b2crypt:${B2_CRYPT_SUBDIR:-}" "$MEDIA" \
	--config "$RCLONE_CONF" \
	--read-only --allow-other \
	--vfs-cache-mode full \
	--vfs-cache-max-size "${RCLONE_CACHE_SIZE:-5G}" --vfs-cache-max-age 72h \
	--cache-dir "$CACHE_DIR" \
	--dir-cache-time 5m --poll-interval 0 \
	--vfs-read-chunk-size 32M --buffer-size 32M \
	--log-level NOTICE &
RCLONE_PID=$!

for _ in $(seq 30); do
	mountpoint -q "$MEDIA" && break
	kill -0 "$RCLONE_PID" 2>/dev/null || { log "rclone terminato: credenziali o endpoint errati?" >&2; exit 1; }
	sleep 1
done
mountpoint -q "$MEDIA" || { log "mount non pronto dopo 30s" >&2; exit 1; }
log "mount pronto"

/jellyfin/jellyfin &
JELLYFIN_PID=$!

shutdown() {
	log "arresto"
	kill -TERM "$JELLYFIN_PID" 2>/dev/null || true
	wait "$JELLYFIN_PID" 2>/dev/null || true
	fusermount3 -uz "$MEDIA" 2>/dev/null || true
	kill -TERM "$RCLONE_PID" 2>/dev/null || true
}
trap 'shutdown; exit 0' TERM INT

set +e
wait -n "$RCLONE_PID" "$JELLYFIN_PID"
status=$?
log "un processo è terminato (exit $status), chiudo il container" >&2
shutdown
exit "$status"
