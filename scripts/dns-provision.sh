#!/bin/sh
# DNS per casa.local con dnsmasq, su tutte le interfacce tranne podman1 (lì c'è
# già aardvark-dns, il DNS dei container), wg0 (la VPN) e le veth dei container.
# casa.local e ogni *.casa.local rispondono con un solo indirizzo: DNS_ADDRESS dal
# .env, altrimenti l'IP Tailscale della VM (tailscale ip -4). NPM smista per nome.
# Senza nessuno dei due, ogni nome risponde con l'IP della VM sull'interfaccia da
# cui arriva la domanda (eth0 / tailscale0), per i nomi di scripts/npm-provision.sh.
# Gli altri domini vengono inoltrati ai DNS di /etc/resolv.conf (quelli della VPN).
set -eu
cd "$(dirname "$0")/.."
envget() { sed -n "s/^$1=//p" .env | tr -d '"'; }
D=$(envget BASE_DOMAIN)
D=${D:-casa.local}
OUT=/etc/dnsmasq.d/seedbox.conf
IFACES="${DNS_IFACES:-eth0 tailscale0}"
ADDR=$(envget DNS_ADDRESS)
[ -n "$ADDR" ] || ADDR=$(tailscale ip -4 2>/dev/null | head -n 1 || true)

names=$(sed -n '/^HOSTS="/,/^"/p' scripts/npm-provision.sh | grep '|' | cut -d'|' -f1 \
	| tr ' ' '\n' | sed "s/\$D/$D/" | sort -u)

mkdir -p /etc/dnsmasq.d
{
	echo "# Generato da scripts/dns-provision.sh: non modificare a mano"
	echo "bind-dynamic"
	echo "except-interface=podman1"
	echo "except-interface=wg0"
	echo "except-interface=veth*"
	echo "domain-needed"
	echo "bogus-priv"
	echo "local=/$D/"
	if [ -n "$ADDR" ]; then
		echo "address=/$D/$ADDR"
	else
		echo "localise-queries"
		for n in $names; do
			for i in $IFACES; do echo "interface-name=$n,$i/4"; done
		done
	fi
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

dnsmasq --test -C /etc/dnsmasq.conf
rc-update add dnsmasq default >/dev/null
rc-service dnsmasq restart
if [ -n "$ADDR" ]; then
	echo "dnsmasq: $D e *.$D -> $ADDR"
else
	echo "dnsmasq: $(echo "$names" | wc -l) nomi su $IFACES (IP dell'interfaccia)"
fi
