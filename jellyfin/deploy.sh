#!/bin/sh
# Crea (se serve) app e volume su Fly, carica le chiavi B2 come secrets e fa il deploy.
# Requisiti: flyctl installato e `fly auth login` fatto.
set -eu

cd "$(dirname "$0")"
[ -f .env ] || { echo "Manca jellyfin/.env (copia .env.example)" >&2; exit 1; }
. ./.env

FLY=$(command -v fly || command -v flyctl || true)
[ -n "$FLY" ] || { [ -x "$HOME/.fly/bin/fly" ] && FLY="$HOME/.fly/bin/fly"; } || true
[ -n "$FLY" ] || { echo "flyctl non trovato: curl -L https://fly.io/install.sh | sh" >&2; exit 1; }
[ -n "${B2_KEY_ID:-}" ] && [ -n "${B2_APP_KEY:-}" ] || { echo "B2_KEY_ID/B2_APP_KEY vuoti in .env" >&2; exit 1; }
: "${FLY_APP:?FLY_APP vuoto in .env}"

# fly.toml reale (non nel repo) generato dal modello: nome app da .env, bucket dal .env principale
BUCKET=$(sed -n 's/^B2_BUCKET=//p' ../.env 2>/dev/null | tr -d '"')
[ -n "$BUCKET" ] || { echo "B2_BUCKET mancante in ../.env" >&2; exit 1; }
sed -e "s/<app-fly>/$FLY_APP/g" -e "s/<bucket>/$BUCKET/g" fly.toml.example > fly.toml

REGION=$(sed -n 's/^primary_region = "\([a-z]*\)".*/\1/p' fly.toml)

if ! "$FLY" status -a "$FLY_APP" >/dev/null 2>&1; then
	echo "==> Creo l'app $FLY_APP"
	"$FLY" apps create "$FLY_APP"
fi

if ! "$FLY" volumes list -a "$FLY_APP" 2>/dev/null | grep -q jellyfin_data; then
	echo "==> Creo il volume jellyfin_data ($REGION, 10GB)"
	"$FLY" volumes create jellyfin_data -a "$FLY_APP" --region "$REGION" --size 10 --yes
fi

# chiavi di cifratura rclone: dal .env principale della seedbox (devono coincidere)
MAIN_ENV=../.env
CRYPT1=$(sed -n 's/^B2_CRYPT_PASSWORD=//p' "$MAIN_ENV" 2>/dev/null | tr -d '"')
CRYPT2=$(sed -n 's/^B2_CRYPT_PASSWORD2=//p' "$MAIN_ENV" 2>/dev/null | tr -d '"')
[ -n "$CRYPT1" ] && [ -n "$CRYPT2" ] || {
	echo "B2_CRYPT_PASSWORD/B2_CRYPT_PASSWORD2 mancanti in $MAIN_ENV" >&2; exit 1; }

echo "==> Secrets (chiave B2 read-only + chiavi di cifratura)"
"$FLY" secrets set -a "$FLY_APP" --stage B2_KEY_ID="$B2_KEY_ID" B2_APP_KEY="$B2_APP_KEY" \
	B2_CRYPT_PASSWORD="$CRYPT1" B2_CRYPT_PASSWORD2="$CRYPT2"

echo "==> Deploy"
"$FLY" deploy -a "$FLY_APP" --ha=false

echo "Jellyfin: https://$FLY_APP.fly.dev"
