#!/bin/sh
# Protegge il disco locale (incompleti + cache rclone): sotto DISK_GUARD_MIN_GB liberi
# ferma tutti i download incompleti di qBittorrent, sopra DISK_GUARD_RESUME_GB riavvia
# solo quelli fermati da qui. Forza anche download sequenziale + primo/ultimo pezzo
# su tutti i download (scrivono direttamente sul mount B2, senza cartella incompleti).

ENV_FILE="$(dirname "$0")/../.env"
envget() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tr -d '"'; }

MIN_GB="${DISK_GUARD_MIN_GB:-$(envget DISK_GUARD_MIN_GB)}"; MIN_GB="${MIN_GB:-2}"
RESUME_GB="${DISK_GUARD_RESUME_GB:-$(envget DISK_GUARD_RESUME_GB)}"; RESUME_GB="${RESUME_GB:-4}"
INCOMPLETE="$(envget LOCAL_INCOMPLETE)"; INCOMPLETE="${INCOMPLETE:-/srv/seedbox/incomplete}"
CACHE_DIR="$(envget RCLONE_CACHE_DIR)"; CACHE_DIR="${CACHE_DIR:-/var/cache/rclone}"
QBIT_URL="${QBIT_URL:-http://127.0.0.1:8080}"
STATE="${DISK_GUARD_STATE:-/var/lib/seedbox/disk-guard.paused}"
INTERVAL=20

log() { echo "$(date '+%F %T') $*"; }
api() { p=$1; shift; curl -fsS --max-time 10 "$QBIT_URL/api/v2/$p" "$@"; }

# spazio libero minimo (in MB) tra i filesystem degli incompleti e della cache
free_mb() {
	for p in "$INCOMPLETE" "$CACHE_DIR"; do
		[ -e "$p" ] || p=$(dirname "$p")
		df -Pm "$p" 2>/dev/null | awk 'NR==2 {print $4}'
	done | sort -n | head -n 1
}

log "start (stop < ${MIN_GB}G, riavvio > ${RESUME_GB}G)"
while :; do
	free=$(free_mb)
	torrents=$(api torrents/info 2>/dev/null)
	if [ -z "$free" ] || [ -z "$torrents" ]; then
		sleep "$INTERVAL"; continue
	fi

	if [ "$free" -lt $((MIN_GB * 1024)) ]; then
		# tutti gli incompleti non già fermi (anche in coda, altrimenti partirebbero)
		hashes=$(printf '%s' "$torrents" | jq -r \
			'.[] | select(.progress < 1 and (.state | startswith("stopped") | not)) | .hash')
		if [ -n "$hashes" ]; then
			printf '%s\n' "$hashes" >> "$STATE"
			sort -u -o "$STATE" "$STATE"
			api torrents/stop --data-urlencode "hashes=$(printf '%s' "$hashes" | paste -sd '|')" >/dev/null \
				&& log "spazio libero ${free}M: fermati $(printf '%s\n' "$hashes" | wc -l) download"
		fi
	elif [ "$free" -gt $((RESUME_GB * 1024)) ] && [ -s "$STATE" ]; then
		api torrents/start --data-urlencode "hashes=$(paste -sd '|' "$STATE")" >/dev/null \
			&& { log "spazio libero ${free}M: riavviati $(wc -l < "$STATE") download"; : > "$STATE"; }
	fi

	# download sequenziale e primo/ultimo pezzo, così i file si
	# completano uno alla volta, vengono chiusi, caricati su B2 e tolti dalla cache
	seq=$(printf '%s' "$torrents" | jq -r '.[] | select(.progress < 1 and (.seq_dl | not)) | .hash' | paste -sd '|')
	[ -n "$seq" ] && api torrents/toggleSequentialDownload --data-urlencode "hashes=$seq" >/dev/null
	flp=$(printf '%s' "$torrents" | jq -r '.[] | select(.progress < 1 and (.f_l_piece_prio | not)) | .hash' | paste -sd '|')
	[ -n "$flp" ] && api torrents/toggleFirstLastPiecePrio --data-urlencode "hashes=$flp" >/dev/null

	sleep "$INTERVAL"
done
