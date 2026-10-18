#!/bin/sh
# Prepara Audiobookshelf via API (idempotente): utente admin dal .env, watcher dei
# file spento (su /data, mount FUSE, non funziona) e le librerie Libri e Audiolibri
# con una nuova scansione ogni 6 ore.
set -eu
cd "$(dirname "$0")/.."
. ./.env
API="${ABS_URL:-http://127.0.0.1:13378}"
: "${ABS_ADMIN_USER:?ABS_ADMIN_USER vuoto in .env}" "${ABS_ADMIN_PASSWORD:?ABS_ADMIN_PASSWORD vuoto in .env}"

echo "Attendo Audiobookshelf..."
i=0
until curl -fsS --max-time 3 "$API/status" >/dev/null 2>&1; do
	i=$((i + 1)); [ $i -lt 60 ] || { echo "Audiobookshelf non risponde su $API" >&2; exit 1; }
	sleep 2
done

if [ "$(curl -fsS "$API/status" | jq -r .isInit)" != true ]; then
	jq -n --arg u "$ABS_ADMIN_USER" --arg p "$ABS_ADMIN_PASSWORD" '{newRoot: {username: $u, password: $p}}' \
		| curl -fsS -o /dev/null "$API/init" -H 'Content-Type: application/json' -d @-
	echo "+ utente $ABS_ADMIN_USER"
fi

token=$(jq -n --arg u "$ABS_ADMIN_USER" --arg p "$ABS_ADMIN_PASSWORD" '{username: $u, password: $p}' \
	| curl -fsS "$API/login" -H 'Content-Type: application/json' -d @- | jq -r .user.token)
[ -n "$token" ] && [ "$token" != null ] || { echo "Login Audiobookshelf fallito" >&2; exit 1; }
auth="Authorization: Bearer $token"

curl -fsS -o /dev/null -X PATCH "$API/api/settings" -H "$auth" -H 'Content-Type: application/json' \
	-d '{"scannerDisableWatcher": true}'

# nome | cartella | provider dei metadati
LIBS="
Libri|/data/media/books|google
Audiolibri|/data/media/audiobooks|audible.it
"
existing=$(curl -fsS "$API/api/libraries" -H "$auth" | jq -c '.libraries')
echo "$LIBS" | while IFS='|' read -r name dir provider; do
	[ -n "$name" ] || continue
	if printf '%s' "$existing" | jq -e --arg d "$dir" 'any(.[]; any(.folders[]; .fullPath == $d))' >/dev/null; then
		echo "= $name"
		continue
	fi
	jq -n --arg n "$name" --arg d "$dir" --arg p "$provider" '{
		name: $n, mediaType: "book", provider: $p, folders: [{fullPath: $d}],
		settings: {autoScanCronExpression: "0 */6 * * *", skipMatchingMediaWithAsin: false}
	}' | curl -fsS -o /dev/null "$API/api/libraries" -H "$auth" -H 'Content-Type: application/json' -d @- \
		&& echo "+ $name ($dir)" || echo "! errore creando $name" >&2
done
