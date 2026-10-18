#!/bin/sh
# Installazione/aggiornamento della seedbox. Da eseguire come root:
#   doas ./setup.sh
# Idempotente: si può rilanciare (es. dopo aver montato il disco dati).
set -eu

[ "$(id -u)" -eq 0 ] || { echo "Esegui come root (doas ./setup.sh)" >&2; exit 1; }

DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"
export DOCKER_HOST=unix:///run/podman/podman.sock

echo "==> Pacchetti"
apk add --quiet docker-cli-compose libnatpmp curl jq openssl xxd rclone fuse3 mount e2fsprogs-extra

echo "==> .env"
if [ ! -f .env ]; then
	cp .env.example .env
	sed -i "s/^NPM_ADMIN_PASSWORD=$/NPM_ADMIN_PASSWORD=$(openssl rand -hex 12)/" .env
	sed -i "s/^QBIT_PASS=$/QBIT_PASS=$(openssl rand -hex 12)/" .env
	echo "    creato .env con password generate"
fi
# chiavi di cifratura rclone: generate una sola volta, mai sovrascritte
for k in B2_CRYPT_PASSWORD B2_CRYPT_PASSWORD2; do
	grep -q "^$k=" .env || echo "$k=" >> .env
	if grep -q "^$k=$" .env; then
		sed -i "s/^$k=$/$k=$(openssl rand -hex 32)/" .env
		echo "    generata $k: salvala altrove, senza non si recuperano i dati su B2"
	fi
done
grep -q '^FILEBROWSER_USER=' .env || printf '\nFILEBROWSER_USER=admin\n' >> .env
grep -q '^FILEBROWSER_PASS=' .env || echo 'FILEBROWSER_PASS=' >> .env
sed -i "s/^FILEBROWSER_PASS=$/FILEBROWSER_PASS=$(openssl rand -hex 12)/" .env
chown 1000:1000 .env && chmod 600 .env
. ./.env
: "${B2_BUCKET:=}" "${LOCAL_INCOMPLETE:=/srv/seedbox/incomplete}"

mkdir -p "$LOCAL_INCOMPLETE"
chown "$PUID:$PGID" "$LOCAL_INCOMPLETE"

if [ -n "$B2_BUCKET" ]; then
	echo "==> Storage: Backblaze B2 ($B2_BUCKET/${B2_PATH:-}) su $DATA_ROOT"
	STORAGE=rclone-b2
	# le cartelle vengono create dal servizio rclone-b2 dopo il mount
else
	echo "==> Storage: disco locale $DATA_ROOT"
	STORAGE=
	mountpoint -q "$DATA_ROOT" || echo "    ATTENZIONE: $DATA_ROOT non è un mountpoint (disco dati non montato?)"
	for d in torrents media; do
		for s in tv movies music books; do mkdir -p "$DATA_ROOT/$d/$s"; done
	done
	chown -R "$PUID:$PGID" "$DATA_ROOT/torrents" "$DATA_ROOT/media"
	chown "$PUID:$PGID" "$DATA_ROOT"
	find "$DATA_ROOT/torrents" "$DATA_ROOT/media" -type d -exec chmod 2775 {} +
fi

echo "==> Config"
for app in qbittorrent prowlarr sonarr radarr lidarr readarr bazarr seerr; do
	mkdir -p "config/$app"
done
mkdir -p config/npm/data config/npm/letsencrypt
mkdir -p config/filebrowser/config config/filebrowser/database
chown -R "$PUID:$PGID" config/qbittorrent config/prowlarr config/sonarr config/radarr \
	config/lidarr config/readarr config/bazarr config/seerr config/filebrowser

FB_DB=config/filebrowser/database/filebrowser.db
if [ ! -f "$FB_DB" ]; then
	echo "    File Browser: database e utente $FILEBROWSER_USER"
	cat > config/filebrowser/config/settings.json <<EOF
{
  "port": 80,
  "baseURL": "",
  "address": "",
  "log": "stdout",
  "database": "/database/filebrowser.db",
  "root": "/srv"
}
EOF
	chown "$PUID:$PGID" config/filebrowser/config/settings.json
	fb() {
		podman run --rm --user "$PUID:$PGID" --entrypoint filebrowser \
			-v "$DIR/config/filebrowser/database:/database" \
			docker.io/filebrowser/filebrowser:v2.63.23-s6 -d /database/filebrowser.db "$@"
	}
	fb config init --root /srv --address 0.0.0.0 --port 80 \
		--branding.name "Seedbox" --branding.disableExternal >/dev/null
	fb users add "$FILEBROWSER_USER" "$FILEBROWSER_PASS" \
		--perm.admin --perm.execute=false --hideDotfiles --locale it >/dev/null
fi

QB=config/qbittorrent/qBittorrent
if [ ! -f "$QB/qBittorrent.conf" ]; then
	echo "    qBittorrent: preconfigurazione (wg0, /data/torrents, credenziali)"
	mkdir -p "$QB"
	salt=$(openssl rand -hex 16)
	hash=$(openssl kdf -keylen 64 -kdfopt digest:SHA512 -kdfopt "pass:$QBIT_PASS" \
		-kdfopt "hexsalt:$salt" -kdfopt iter:100000 -binary PBKDF2 | base64 -w0)
	salt64=$(echo "$salt" | xxd -r -p | base64 -w0)
	cat > "$QB/qBittorrent.conf" <<EOF
[BitTorrent]
Session\DefaultSavePath=/data/torrents
Session\TempPathEnabled=false
Session\TempPath=/incomplete
Session\Interface=wg0
Session\InterfaceName=wg0
Session\Port=6881
Session\UseRandomPort=false

[LegalNotice]
Accepted=true

[Network]
PortForwardingEnabled=false

[Preferences]
Connection\UPnP=false
WebUI\Port=8080
WebUI\Username=$QBIT_USER
WebUI\Password_PBKDF2="@ByteArray($salt64:$hash)"
WebUI\LocalHostAuth=false
WebUI\HostHeaderValidation=false
EOF
	cat > "$QB/categories.json" <<EOF
{
    "tv": { "save_path": "/data/torrents/tv" },
    "movies": { "save_path": "/data/torrents/movies" },
    "music": { "save_path": "/data/torrents/music" },
    "books": { "save_path": "/data/torrents/books" }
}
EOF
	chown -R "$PUID:$PGID" config/qbittorrent
fi

echo "==> Servizi OpenRC"
chmod 755 scripts/* openrc/* setup.sh
install -m 755 openrc/seedbox-core /etc/init.d/seedbox-core
install -m 755 openrc/seedbox /etc/init.d/seedbox
install -m 755 openrc/seedbox-natpmp /etc/init.d/seedbox-natpmp
install -m 755 openrc/rclone-b2 /etc/init.d/rclone-b2
install -m 755 openrc/seedbox-diskguard /etc/init.d/seedbox-diskguard
install -m 755 openrc/seedbox-status /etc/init.d/seedbox-status
for svc in seedbox-core seedbox seedbox-natpmp seedbox-diskguard seedbox-status rclone-b2; do
	printf 'SEEDBOX_DIR="%s"\n' "$DIR" > "/etc/conf.d/$svc"
done
printf 'SEEDBOX_STORAGE="%s"\n' "$STORAGE" >> /etc/conf.d/seedbox
rc-update add ntpd default >/dev/null	# orologio giusto: firme S3 di B2 e pagina di stato
rc-service ntpd start >/dev/null 2>&1 || true
rc-update add podman default >/dev/null
rc-update add seedbox-core default >/dev/null
rc-update add seedbox default >/dev/null
rc-update add seedbox-natpmp default >/dev/null
rc-update add seedbox-diskguard default >/dev/null
rc-update add seedbox-status default >/dev/null
if [ -n "$STORAGE" ]; then
	rc-update add rclone-b2 default >/dev/null
else
	rc-update del rclone-b2 default >/dev/null 2>&1 || true
fi

mkdir -p /var/lib/seedbox/status
# link di Jellyfin per la dashboard casa.local (il nome dell'app Fly non sta nel repo)
app=$(sed -n 's/^FLY_APP=//p' jellyfin/.env 2>/dev/null | tr -d '"')
[ -n "$app" ] && jq -n --arg u "https://$app.fly.dev" '{jellyfin: $u}' > /var/lib/seedbox/status/links.json

echo "==> Immagini"
docker compose pull
docker compose -f core.yaml pull

echo "==> Avvio"
rc-service podman start >/dev/null 2>&1 || true
# lo stack va fermato prima di montare B2 sopra /data
rc-service seedbox stop >/dev/null 2>&1 || true
if [ -n "$STORAGE" ]; then
	rc-service rclone-b2 restart
else
	rc-service rclone-b2 stop >/dev/null 2>&1 || true
fi
rc-service seedbox-core start
rc-service seedbox start
rc-service seedbox-natpmp restart
rc-service seedbox-diskguard restart
rc-service seedbox-status restart

echo "==> qBittorrent: incompleti in locale, categoria b2 diretta su B2, I/O POSIX"
i=0
until curl -fsS --max-time 3 http://127.0.0.1:8080/api/v2/app/version >/dev/null 2>&1; do
	i=$((i + 1)); [ $i -lt 30 ] || break; sleep 2
done
curl -fsS http://127.0.0.1:8080/api/v2/app/setPreferences \
	--data-urlencode 'json={"temp_path_enabled":false,"temp_path":"/incomplete","disk_io_type":2,"file_pool_size":20}' \
	|| echo "    impossibile aggiornare qBittorrent (impostalo a mano: Opzioni → Download)"

# categoria b2: niente cartella incompleti, scrive direttamente sul mount B2
mkdir -p "$DATA_ROOT/torrents/b2" && touch "$DATA_ROOT/torrents/b2/.keep"
curl -fsS http://127.0.0.1:8080/api/v2/torrents/createCategory \
	--data-urlencode category=b2 --data-urlencode savePath=/data/torrents/b2 \
	--data-urlencode downloadPathEnabled=false >/dev/null 2>&1 || true

echo "==> Proxy host Nginx Proxy Manager (*.$BASE_DOMAIN)"
./scripts/npm-provision.sh

cat <<EOF

Fatto.
  NPM admin:    http://npm.$BASE_DOMAIN  (o :81)  $NPM_ADMIN_EMAIL / password in .env
  qBittorrent:  http://qbittorrent.$BASE_DOMAIN   $QBIT_USER / password in .env
Aggiungi sul client: <ip-seedbox>  $BASE_DOMAIN npm.$BASE_DOMAIN qbittorrent.$BASE_DOMAIN ...
(vedi README.md)
EOF
