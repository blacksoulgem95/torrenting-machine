#!/bin/sh
# Consente all'utente indicato (default: seedbox) di usare doas senza password.
# Da eseguire come root una volta:  su -c ./override-doas.sh   (o doas ./override-doas.sh)
# Per annullare: rm /etc/doas.d/90-nopass-<utente>.conf
set -eu

[ "$(id -u)" -eq 0 ] || { echo "Esegui come root (su -c $0)" >&2; exit 1; }

USER_NAME="${1:-seedbox}"
id "$USER_NAME" >/dev/null 2>&1 || { echo "Utente $USER_NAME inesistente" >&2; exit 1; }

RULE="permit nopass $USER_NAME as root"

if [ -d /etc/doas.d ]; then
	CONF="/etc/doas.d/90-nopass-$USER_NAME.conf"
	TMP=$(mktemp)
	echo "$RULE" > "$TMP"
	doas -C "$TMP" || { rm -f "$TMP"; echo "Regola non valida" >&2; exit 1; }
	install -m 0400 -o root -g root "$TMP" "$CONF"
	rm -f "$TMP"
else
	CONF=/etc/doas.conf
	grep -qxF "$RULE" "$CONF" 2>/dev/null || echo "$RULE" >> "$CONF"
	chmod 0400 "$CONF"
	doas -C "$CONF"
fi

echo "OK: $USER_NAME può usare doas senza password ($CONF)"
