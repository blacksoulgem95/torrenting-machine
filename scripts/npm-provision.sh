#!/bin/sh
# Crea in Nginx Proxy Manager i proxy host {software}.$BASE_DOMAIN via API.
# Idempotente: crea i domini mancanti e corregge destinazione/porta di quelli esistenti.
set -eu

cd "$(dirname "$0")/.."
. ./.env

API="http://127.0.0.1:81/api"
D="$BASE_DOMAIN"

# qBittorrent è in rete host: nginx non legge /etc/hosts (host.containers.internal),
# quindi uso l'IP del gateway della rete seedbox, cioè l'host visto dai container.
HOST_GW=$(DOCKER_HOST=unix:///run/podman/podman.sock docker network inspect seedbox \
	-f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
HOST_GW=${HOST_GW:-10.89.0.1}

# dominio(i) | host di destinazione | porta
HOSTS="
npm.$D|127.0.0.1|81
$D|home|8080
qbittorrent.$D qbit.$D|$HOST_GW|8080
prowlarr.$D|prowlarr|9696
sonarr.$D|sonarr|8989
radarr.$D|radarr|7878
lidarr.$D|lidarr|8686
readarr.$D|readarr|8787
bazarr.$D|bazarr|6767
seerr.$D overseerr.$D|seerr|5055
fm.$D|filebrowser|80
rclone.$D|rclone-status|8080
"

echo "Attendo l'API di Nginx Proxy Manager..."
i=0
until curl -fsS --max-time 3 "$API/" 2>/dev/null | grep -q '"OK"'; do
	i=$((i + 1))
	[ $i -lt 90 ] || { echo "NPM non risponde su $API" >&2; exit 1; }
	sleep 2
done

token=$(jq -n --arg i "$NPM_ADMIN_EMAIL" --arg s "$NPM_ADMIN_PASSWORD" '{identity:$i, secret:$s}' \
	| curl -fsS "$API/tokens" -H 'Content-Type: application/json' -d @- | jq -r .token)
[ -n "$token" ] && [ "$token" != null ] || { echo "Login NPM fallito" >&2; exit 1; }
auth="Authorization: Bearer $token"


echo "$HOSTS" | while IFS='|' read -r domains host port; do
	[ -n "$domains" ] || continue
	first=${domains%% *}
	# riletti a ogni voce: quella prima può aver appena tolto un dominio a un host
	existing=$(curl -fsS "$API/nginx/proxy-hosts" -H "$auth")
	cur=$(printf '%s' "$existing" | jq -c --arg f "$first" \
		'[.[] | select(.domain_names | index($f))][0] // empty')
	if [ -n "$cur" ]; then
		id=$(printf '%s' "$cur" | jq -r .id)
		want="$(printf "%s\n" $domains | sort | tr "\n" " " | sed "s/ $//")|$host:$port"
		have=$(printf '%s' "$cur" | jq -r '"\(.domain_names | sort | join(" "))|\(.forward_host):\(.forward_port)"')
		if [ "$have" = "$want" ]; then
			echo "= $first"
			continue
		fi
		jq -n --arg d "$domains" --arg h "$host" --argjson p "$port" \
			'{domain_names: ($d | split(" ")), forward_host: $h, forward_port: $p}' \
			| curl -fsS -o /dev/null -X PUT "$API/nginx/proxy-hosts/$id" -H "$auth" \
				-H 'Content-Type: application/json' -d @- \
			&& echo "~ $domains -> $host:$port (aggiornato)" \
			|| echo "! errore aggiornando $first" >&2
		continue
	fi
	jq -n --arg d "$domains" --arg h "$host" --argjson p "$port" '{
		domain_names: ($d | split(" ")),
		forward_scheme: "http", forward_host: $h, forward_port: $p,
		access_list_id: 0, certificate_id: 0, ssl_forced: false,
		http2_support: false, hsts_enabled: false, hsts_subdomains: false,
		caching_enabled: false, block_exploits: true, allow_websocket_upgrade: true,
		advanced_config: "", locations: [], meta: {}
	}' | curl -fsS -o /dev/null "$API/nginx/proxy-hosts" -H "$auth" \
		-H 'Content-Type: application/json' -d @- \
		&& echo "+ $domains -> $host:$port" \
		|| echo "! errore creando $domains" >&2
done
