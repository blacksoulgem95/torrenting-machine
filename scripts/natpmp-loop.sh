#!/bin/sh
# Loop NAT-PMP per ProtonVPN: ogni 45s richiede (o rinnova) la porta pubblica
# e la imposta come listen_port di qBittorrent se è cambiata.
# qBittorrent ha "bypass auth per localhost" attivo, quindi niente login.

ENV_FILE="$(dirname "$0")/../.env"
GW="${NATPMP_GATEWAY:-$(sed -n 's/^NATPMP_GATEWAY=//p' "$ENV_FILE" 2>/dev/null)}"
GW="${GW:-10.2.0.1}"
QBIT_URL="${QBIT_URL:-http://127.0.0.1:8080}"
INTERVAL=45

log() { echo "$(date '+%F %T') $*"; }

qbit_port() {
	curl -fsS --max-time 5 "$QBIT_URL/api/v2/app/preferences" \
		| sed -n 's/.*"listen_port":\([0-9]*\).*/\1/p'
}

set_qbit_port() {
	curl -fsS --max-time 5 "$QBIT_URL/api/v2/app/setPreferences" \
		--data-urlencode "json={\"listen_port\":$1,\"random_port\":false,\"upnp\":false}"
}

log "start (gateway $GW)"
while :; do
	if natpmpc -g "$GW" -a 1 0 udp 60 >/dev/null \
		&& out=$(natpmpc -g "$GW" -a 1 0 tcp 60); then
		port=$(printf '%s\n' "$out" | sed -n 's/.*Mapped public port \([0-9]*\) protocol TCP.*/\1/p' | tail -n 1)
		current=$(qbit_port)
		if [ -z "$port" ]; then
			log "porta non trovata nell'output di natpmpc"
		elif [ -z "$current" ]; then
			log "qBittorrent non raggiungibile su $QBIT_URL"
		elif [ "$port" != "$current" ]; then
			if set_qbit_port "$port"; then
				log "listen_port $current -> $port"
			else
				log "impossibile impostare listen_port $port"
			fi
		fi
	else
		log "natpmpc fallito (port forwarding attivo nella config WireGuard Proton?)"
	fi
	sleep "$INTERVAL"
done
