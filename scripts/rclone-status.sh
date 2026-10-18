#!/bin/sh
# Scrive per la pagina rclone.casa.local:
#   $STATUS_DIR/status.json  - ogni secondo: cache VFS, coda verso B2, file in
#                              caricamento (nome + avanzamento), dischi, RAM, CPU
#   $STATUS_DIR/history.json - ogni 5s, ultima ora di campioni (medie) per i grafici
# Le parti costose (salute dei dischi, log di rclone, du) girano più di rado.
# Gira come root (tune2fs, dmesg, password rc).

STATUS_DIR="${STATUS_DIR:-/var/lib/seedbox/status}"
RC_URL="${RC_URL:-http://127.0.0.1:5572}"
RC_PASS_FILE=/etc/rclone/rc.pass
GUARD_STATE=/var/lib/seedbox/disk-guard.paused
DISKS="${STATUS_DISKS:-/srv/seedbox /}"
DATA_DISK="${STATUS_DATA_DISK:-/srv/seedbox}"
INTERVAL=1                  # status.json
SLOW_EVERY=5                # storico, salute dei dischi, avvio di rclone: ogni 5s
HISTORY_POINTS=720          # 1 ora a 5s
DU_EVERY=60                 # composizione del disco dati ogni minuto
RCLONE_LOG=/var/log/rclone-b2.log
ENV_FILE="$(dirname "$0")/../.env"
CACHE_META="$(sed -n 's/^RCLONE_CACHE_DIR=//p' "$ENV_FILE" | tr -d '"')"
CACHE_META="${CACHE_META:-/srv/seedbox/rclone-cache}/vfsMeta"

rc() {
	curl -fsS --max-time 4 -u "seedbox:$(cat "$RC_PASS_FILE" 2>/dev/null)" \
		-H 'Content-Type: application/json' -d '{}' "$RC_URL/$1" 2>/dev/null
}

# salute di un mount: spazio, inode, sola lettura, stato ext4, errori I/O nel kernel
disk_json() {
	mnt=$1
	dev=$(awk -v m="$mnt" '$2 == m {print $1}' /proc/mounts | tail -n 1)
	opts=$(awk -v m="$mnt" '$2 == m {print $4}' /proc/mounts | tail -n 1)
	fstype=$(awk -v m="$mnt" '$2 == m {print $3}' /proc/mounts | tail -n 1)
	set -- $(df -Pk "$mnt" | awk 'NR==2 {print $2, $3, $4}')
	size=$(($1 * 1024)) used=$(($2 * 1024)) avail=$(($3 * 1024))
	set -- $(df -Pi "$mnt" 2>/dev/null | awk 'NR==2 {print $2, $3}')
	inodes=${1:-0} inodes_used=${2:-0}
	state="" errors=0 label=""
	if [ "$fstype" = ext4 ] && [ -b "$dev" ]; then
		info=$(tune2fs -l "$dev" 2>/dev/null)
		state=$(printf '%s\n' "$info" | sed -n 's/^Filesystem state: *//p')
		errors=$(printf '%s\n' "$info" | sed -n 's/^FS Error count: *//p')
		label=$(printf '%s\n' "$info" | sed -n 's/^Filesystem volume name: *//p' | grep -v '^<none>$')
	fi
	short=${dev#/dev/}
	ioerr=$(dmesg 2>/dev/null | grep -E "I/O error|EXT4-fs error|Buffer I/O" | grep -c "$short")
	jq -n --arg mount "$mnt" --arg dev "$dev" --arg fstype "$fstype" --arg label "$label" \
		--arg state "$state" --arg opts "$opts" \
		--argjson size "$size" --argjson used "$used" --argjson avail "$avail" \
		--argjson inodes "$inodes" --argjson inodes_used "$inodes_used" \
		--argjson fs_errors "${errors:-0}" --argjson io_errors "${ioerr:-0}" '{
		mount: $mount, device: $dev, fstype: $fstype, label: $label,
		size: $size, used: $used, avail: $avail,
		inodes: $inodes, inodes_used: $inodes_used,
		readonly: ($opts | split(",") | index("ro") != null),
		fs_state: $state, fs_errors: $fs_errors, io_errors: $io_errors,
		smart: "non disponibile (disco virtuale virtio)"
	}'
}

# contatori CPU cumulativi: "attivi_utente attivi_sistema iowait totale"
cpu_counters() {
	read -r _ u n s i w irq sirq st _ < /proc/stat
	echo "$((u + n)) $((s + irq + sirq + st)) $w $((u + n + s + i + w + irq + sirq + st))"
}

# settori letti/scritti del device di un mount
disk_counters() {
	dev=$(awk -v m="$1" '$2 == m {print $1}' /proc/mounts | tail -n 1)
	awk -v d="${dev#/dev/}" '$3 == d {print $6 * 512, $10 * 512}' /proc/diskstats
}

mkdir -p "$STATUS_DIR"
WORK=/run/seedbox-status
mkdir -p "$WORK" && chmod 700 "$WORK"
chmod 755 "$STATUS_DIR"
[ -s "$STATUS_DIR/history.json" ] || echo '[]' > "$STATUS_DIR/history.json"
echo "$(date '+%F %T') start (status.json ogni ${INTERVAL}s, storico ogni $((INTERVAL * SLOW_EVERY))s)"

# secondi dall'avvio con i centesimi: con un giro da ~1s serve più precisione di date +%s
uptime_s() { cut -d' ' -f1 /proc/uptime; }

# CPU (% sul totale, tutte le CPU) tra due letture di cpu_counters
cpu_json() {
	echo "$1 $2" | awk '{dt = $8 - $4; if (dt <= 0) dt = 1;
		printf "{\"user\":%.1f,\"system\":%.1f,\"iowait\":%.1f}", ($5-$1)*100/dt, ($6-$2)*100/dt, ($7-$3)*100/dt}'
}

# I/O (byte/s) tra due letture di disk_counters, a distanza di $3 secondi
io_json() {
	echo "$1 $2" | awk -v dt="$3" 'NF == 4 {if (dt <= 0) dt = 1; r = ($3-$1)/dt; w = ($4-$2)/dt;
		printf "{\"read\":%.0f,\"write\":%.0f}", (r < 0 ? 0 : r), (w < 0 ? 0 : w)} NF != 4 {print "{\"read\":0,\"write\":0}"}'
}

# byte/s caricati verso B2 tra due letture di core/stats (azzerate al riavvio di rclone)
up_rate() {
	awk -v a="$1" -v b="$2" -v dt="$3" 'BEGIN {if (a == "" || b == "" || b + 0 < a + 0 || dt <= 0) print 0;
		else printf "%.0f", (b - a) / dt}'
}

prev_cpu=$(cpu_counters) h_cpu=$prev_cpu
prev_io=$(disk_counters "$DATA_DISK") h_io=$prev_io
prev_up="" h_up="" prev_t=$(uptime_s) h_t=$prev_t
iter=0 du_incomplete=0 du_cache=0 disks="[]" startup=null

while :; do
	sleep "$INTERVAL"
	now=$(date +%s) t=$(uptime_s)
	dt=$(awk -v a="$prev_t" -v b="$t" 'BEGIN {print b - a}')
	slow=$([ $((iter % SLOW_EVERY)) -eq 0 ] && echo 1)

	# risposte rc su file: la coda può essere enorme e non sta in un argomento di jq
	for c in vfs/stats vfs/queue core/stats; do
		f="$WORK/$(echo "$c" | tr / _).json"
		rc "$c" > "$f" && [ -s "$f" ] || echo null > "$f"
	done
	[ -n "$slow" ] && disks=$(for m in $DISKS; do mountpoint -q "$m" || [ "$m" = / ] && disk_json "$m"; done | jq -s .)
	paused=$(grep -c . "$GUARD_STATE" 2>/dev/null)

	cur_cpu=$(cpu_counters)
	cpu=$(cpu_json "$prev_cpu" "$cur_cpu")
	cur_io=$(disk_counters "$DATA_DISK")
	io=$(io_json "$prev_io" "$cur_io" "$dt")
	cur_up=$(jq -r '.bytes // empty' "$WORK/core_stats.json" 2>/dev/null)
	up=$(up_rate "$prev_up" "$cur_up" "$dt")
	prev_cpu=$cur_cpu prev_io=$cur_io prev_up=$cur_up prev_t=$t

	# RAM (byte)
	mem=$(awk '/^(MemTotal|MemFree|Buffers|Cached|SReclaimable|SwapTotal|SwapFree):/ {v[$1] = $2 * 1024}
		END {cache = v["Buffers:"] + v["Cached:"] + v["SReclaimable:"];
		app = v["MemTotal:"] - v["MemFree:"] - cache; if (app < 0) app = 0;
		printf "{\"total\":%.0f,\"app\":%.0f,\"cache\":%.0f,\"free\":%.0f,\"swap_total\":%.0f,\"swap_used\":%.0f}",
			v["MemTotal:"], app, cache, v["MemFree:"], v["SwapTotal:"], v["SwapTotal:"] - v["SwapFree:"]}' /proc/meminfo)
	load=$(awk '{printf "[%s,%s,%s]", $1, $2, $3}' /proc/loadavg)
	cores=$(grep -c '^processor' /proc/cpuinfo)

	# composizione del disco dati (du è costoso: una volta al minuto)
	if [ $((iter % DU_EVERY)) -eq 0 ] && mountpoint -q "$DATA_DISK"; then
		du_incomplete=$(du -sk "$DATA_DISK/incomplete" 2>/dev/null | awk '{print $1 * 1024}')
		du_cache=$(du -sk "$DATA_DISK/rclone-cache" 2>/dev/null | awk '{print $1 * 1024}')
	fi
	iter=$((iter + 1))

	if [ -n "$slow" ]; then
		# storico: medie sugli ultimi SLOW_EVERY secondi, non l'ultimo campione da 1s
		hdt=$(awk -v a="$h_t" -v b="$t" 'BEGIN {print b - a}')
		sample=$(jq -cn --argjson t "$now" --argjson cpu "$(cpu_json "$h_cpu" "$cur_cpu")" --argjson mem "$mem" \
			--argjson io "$(io_json "$h_io" "$cur_io" "$hdt")" --argjson up "$(up_rate "$h_up" "$cur_up" "$hdt")" \
			'{t: $t, cpu: $cpu, mem: {app: $mem.app, cache: $mem.cache, swap: $mem.swap_used}, io: $io, up: $up}')
		h_cpu=$cur_cpu h_io=$cur_io h_up=$cur_up h_t=$t
		jq -c --argjson s "$sample" --argjson n "$HISTORY_POINTS" '(. + [$s])[-$n:]' \
			"$STATUS_DIR/history.json" > "$STATUS_DIR/history.json.tmp" 2>/dev/null \
			&& mv "$STATUS_DIR/history.json.tmp" "$STATUS_DIR/history.json" \
			|| echo '[]' > "$STATUS_DIR/history.json"

		# avanzamento dall'ultimo avvio di rclone: voci riprese dalla cache e upload riusciti
		ln=$(grep -n 'Serving remote control' "$RCLONE_LOG" 2>/dev/null | tail -n 1 | cut -d: -f1)
		dirty=$(grep -rlE '"Dirty": ?true' "$CACHE_META" 2>/dev/null | wc -l)
		startup=$(tail -n +"${ln:-1}" "$RCLONE_LOG" 2>/dev/null | awk -v d="$dirty" 'NR == 1 {s = $1 " " $2} /queuing for upload/ {q++} /upload succeeded/ {u++}
			END {printf "{\"requeued\":%d,\"uploaded\":%d,\"dirty\":%d,\"since\":\"%s\"}", q, u, d, s}')
	fi
	jq -n \
		--slurpfile vfs_f "$WORK/vfs_stats.json" --slurpfile queue_f "$WORK/vfs_queue.json" \
		--slurpfile core_f "$WORK/core_stats.json" \
		--argjson disks "${disks:-[]}" --argjson paused "${paused:-0}" \
		--argjson mounted "$(mountpoint -q /data && echo true || echo false)" \
		--argjson rclone_running "$(pidof rclone >/dev/null && echo true || echo false)" \
		--argjson queue_limit 100 --argjson interval "$INTERVAL" \
		--argjson startup "${startup:-null}" \
		--argjson cpu "$cpu" --argjson mem "$mem" --argjson load "$load" --argjson cores "$cores" \
		--argjson io "$io" --argjson up "$up" \
		--argjson du_incomplete "${du_incomplete:-0}" --argjson du_cache "${du_cache:-0}" \
		--arg data_disk "$DATA_DISK" \
		--arg updated "$(date -Iseconds)" '
	def nz: . // 0;
	$vfs_f[0] as $vfs | $queue_f[0] as $queue | $core_f[0] as $core
	|
	($queue.queue // []) as $q
	| ($core.transferring // []) as $tr
	| ($disks | map(select(.mount == $data_disk)) | first) as $dd
	| {
		updated: $updated,
		interval: $interval,
		rc_available: ($core != null),
		vfs_ready: ($vfs != null),
		starting: ($rclone_running and ($mounted | not)),
		b2_mounted: $mounted,
		cache: (if $vfs == null then null else {
			used: $vfs.diskCache.bytesUsed,
			max: $vfs.opt.CacheMaxSize,
			files: $vfs.diskCache.files,
			errored: $vfs.diskCache.erroredFiles,
			out_of_space: $vfs.diskCache.outOfSpace,
			in_use: $vfs.inUse
		} end),
		upload: (if $core == null then null else {
			queued_files: ([$q[] | select(.uploading | not)] | length),
			queued_bytes: ([$q[] | select(.uploading | not) | .size] | add | nz),
			uploading_files: ([$q[] | select(.uploading)] | length),
			uploading_bytes: ([$q[] | select(.uploading) | .size] | add | nz),
			uploading_done: ([$tr[] | .bytes] | add | nz),
			retrying_files: ([$q[] | select(.tries > 0)] | length),
			speed: ($core.speed | nz),
			transferred_session: ($core.bytes | nz),
			errors_session: ($core.errors | nz),
			current: [$tr[] | {
				name: .name, size: (.size | nz), bytes: (.bytes | nz),
				percent: (.percentage | nz), speed: ((.speedAvg // .speed) | nz), eta: .eta
			}],
			# prossimi in coda: prima quelli in caricamento, poi per tempo di partenza
			queue_items: ([$q[] | {
				name: .name, size: (.size | nz), tries: (.tries | nz),
				uploading: .uploading, wait: (if .uploading then 0 else (.expiry // 0) end)
			}] | sort_by((.uploading | not), .wait) | .[:$queue_limit])
		} end),
		rclone_running: $rclone_running,
		startup: $startup,
		system: {
			cores: $cores, load: $load, cpu: $cpu, mem: $mem, io: $io, upload_rate: $up
		},
		data_disk: (if $dd == null then null else {
			mount: $dd.mount, size: $dd.size, free: $dd.avail,
			incomplete: $du_incomplete, rclone_cache: $du_cache,
			other: ([$dd.used - $du_incomplete - $du_cache, 0] | max)
		} end),
		disks: $disks,
		guard: { paused_downloads: $paused }
	}' > "$STATUS_DIR/status.json.tmp" && mv "$STATUS_DIR/status.json.tmp" "$STATUS_DIR/status.json"
	chmod 644 "$STATUS_DIR/status.json" "$STATUS_DIR/history.json" 2>/dev/null
done
