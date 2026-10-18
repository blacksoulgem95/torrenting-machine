#!/bin/sh
# Avanzamento di uno spostamento tra due cartelle (mv, File Browser, qBittorrent
# "Imposta percorso"): file e byte già arrivati a destinazione, velocità ed ETA.
# Stampa solo numeri, mai nomi di file.
#
# Uso: scripts/move-progress.sh SORGENTE DESTINAZIONE [secondi tra i controlli, default 30]
#      ONCE=1 scripts/move-progress.sh ...   un solo controllo (velocità ed ETA dal confronto
#                                             con il controllo precedente, se c'è stato)
# Su /data (B2) ogni file spostato è una copia lato server seguita dalla cancellazione:
# la sorgente si svuota e la destinazione si riempie un file alla volta. Il file in
# copia compare a destinazione solo a copia finita, quindi l'avanzamento va a scatti
# sui file grandi. DESTINAZIONE è la cartella che riceve i file spostati (es. la
# cartella del torrent nel nuovo percorso), non la cartella padre già piena: tutto
# quello che contiene conta come "arrivato".

set -u
[ $# -ge 2 ] || { sed -n '5,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
SRC=$1 DST=$2 EVERY=${3:-30}
[ -d "$SRC" ] || [ -d "$DST" ] || { echo "Né sorgente né destinazione esistono" >&2; exit 1; }
STATE="${TMPDIR:-/tmp}/move-progress.$(printf '%s|%s' "$SRC" "$DST" | cksum | cut -d' ' -f1)"

# "file byte" contenuti in una cartella (0 0 se non esiste più)
measure() {
	[ -d "$1" ] || { echo "0 0"; return; }
	files=$(find "$1" -type f 2>/dev/null | wc -l)
	kb=$(du -sk "$1" 2>/dev/null | cut -f1)
	echo "$files $(( ${kb:-0} * 1024 ))"
}

human() { awk -v b="$1" 'BEGIN {split("B KB MB GB TB", u); i = 1; while (b >= 1024 && i < 5) {b /= 1024; i++}
	printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i]}'; }
duration() { awk -v s="$1" 'BEGIN {s = int(s); h = int(s / 3600); m = int(s % 3600 / 60);
	if (h > 0) printf "%dh %02dm", h, m; else if (m > 0) printf "%dm %02ds", m, s % 60; else printf "%ds", s}'; }

check() {
	now=$(date +%s)
	set -- $(measure "$SRC") $(measure "$DST")
	src_f=$1 src_b=$2 dst_f=$3 dst_b=$4
	# il totale resta costante finché non cambia altro nelle due cartelle
	tot_f=$((src_f + dst_f)) tot_b=$((src_b + dst_b))

	# primo controllo di questo spostamento: riferimento per la velocità media
	# (un riferimento più vecchio di un giorno è di uno spostamento interrotto: si riparte)
	[ -s "$STATE" ] && [ -n "$(find "$STATE" -mmin -1440)" ] || rm -f "$STATE"
	if [ -s "$STATE" ]; then read -r t0 b0 f0 < "$STATE"; else t0=$now b0=$dst_b f0=$dst_f; echo "$t0 $b0 $f0" > "$STATE"; fi

	pct=$(awk -v a="$dst_b" -v t="$tot_b" 'BEGIN {printf "%.1f", (t > 0 ? a * 100 / t : 100)}')
	line="$(date +%T)  file $dst_f/$tot_f  dati $(human "$dst_b")/$(human "$tot_b") ($pct%)"

	el=$((now - t0)) moved=$((dst_b - b0))
	if [ "$src_f" -eq 0 ]; then
		line="$line  completato"
		rm -f "$STATE"
	elif [ "$el" -gt 0 ] && [ "$moved" -gt 0 ]; then
		rate=$(awk -v m="$moved" -v e="$el" 'BEGIN {printf "%.0f", m / e}')
		eta=$(awk -v r="$src_b" -v s="$rate" 'BEGIN {printf "%.0f", r / s}')
		fpm=$(awk -v f="$((dst_f - f0))" -v e="$el" 'BEGIN {printf "%.1f", f * 60 / e}')
		line="$line  $(human "$rate")/s, $fpm file/min  ETA $(duration "$eta") (alle $(date -d "@$((now + eta))" +%H:%M 2>/dev/null))"
	else
		line="$line  velocità: serve un altro controllo con dati arrivati"
	fi
	echo "$line"
	[ "$src_f" -gt 0 ]
}

if [ "${ONCE:-}" = 1 ]; then check; exit 0; fi
while check; do sleep "$EVERY"; done
