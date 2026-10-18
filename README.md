# Seedbox (Alpine + Podman + WireGuard)

Stack: qBittorrent, Nginx Proxy Manager, Prowlarr, Sonarr, Radarr,
Lidarr, Bazarr, Seerr (successore di Overseerr), Readarr opzionale.
Jellyfin gira in un ambiente separato: Fly.io, vedi [jellyfin/README.md](jellyfin/README.md).

- Podman **rootful** (servizio OpenRC `podman`), stack gestito con `docker compose`
  sul socket `/run/podman/podman.sock`.
- `seedbox` (OpenRC) avvia lo stack al boot dopo `wg-quick.wg0`; i crash sono
  gestiti da `restart: unless-stopped`.
- Tutto il traffico in uscita passa da wg0 (full tunnel). qBittorrent usa la rete
  host ed è **legato a wg0**: se il tunnel cade non scarica.
- `seedbox-natpmp` rinnova ogni 45s il port forwarding ProtonVPN (NAT-PMP) e
  imposta la porta in qBittorrent. Log: `/var/log/seedbox-natpmp.log`.
  La config WireGuard Proton deve essere generata con *NAT-PMP (Port Forwarding)* attivo.

## Installazione

1. Storage di `/data`, a scelta:
   - **Backblaze B2**: compila in `.env` `B2_KEY_ID`, `B2_APP_KEY`, `B2_BUCKET`,
     `B2_ENDPOINT` (es. `s3.eu-central-003.backblazeb2.com`), `B2_REGION`
     (es. `eu-central-003`) ed eventualmente `B2_PATH`. Vedi sotto.
   - **Disco locale**: lascia `B2_BUCKET` vuoto e monta il disco su `/data` via `/etc/fstab`.
2. `doas ./setup.sh` — installa pacchetti, crea `.env` (password generate),
   `/data/{torrents,media}/{tv,movies,music,books}`, preconfigura qBittorrent,
   installa i servizi OpenRC, avvia e crea i proxy host in NPM.
   È idempotente: rilancialo dopo aver montato il disco.

Credenziali in `.env` (`NPM_ADMIN_*`, `QBIT_*`).
Comandi manuali: `doas scripts/dc ps|logs -f sonarr|pull|up -d`.

## Accesso (Nginx Proxy Manager, `*.casa.local`)

| URL | servizio |
|---|---|
| http://casa.local, http://npm.casa.local | admin NPM |
| http://fm.casa.local | File Browser (gestione file del bucket, cifrato in modo trasparente) |
| http://rclone.casa.local | Stato: coda verso B2, cache rclone, dischi, grafici CPU/RAM/I/O |
| http://qbittorrent.casa.local, http://qbit.casa.local | qBittorrent |
| http://prowlarr.casa.local | Prowlarr |
| http://sonarr.casa.local / radarr / lidarr / bazarr / readarr | *arr |
| http://seerr.casa.local, http://overseerr.casa.local | Seerr |

Sul client (o nel DNS locale) punta tutti i nomi all'IP della seedbox, es. in `/etc/hosts`:

```
<ip-vm> casa.local npm.casa.local fm.casa.local rclone.casa.local qbittorrent.casa.local qbit.casa.local prowlarr.casa.local sonarr.casa.local radarr.casa.local lidarr.casa.local readarr.casa.local bazarr.casa.local seerr.casa.local overseerr.casa.local
```

Note: <rete-vm>/24 è la rete NAT di libvirt (raggiungibile dall'hypervisor o via
suo port forward). `.local` è riservato a mDNS: alcuni client (macOS, Linux con
nss-mdns) possono avere ritardi; in quel caso usa un DNS locale o cambia `BASE_DOMAIN`
in `.env` e rilancia `scripts/npm-provision.sh`. Le porte dirette (8080, 9696, 8989,
7878, 8686, 6767, 5055, 81) restano come fallback.

## Collegamenti tra le app (da fare nelle UI)

- **Prowlarr**: Settings → Apps → Sonarr `http://sonarr:8989`, Radarr
  `http://radarr:7878`, Lidarr `http://lidarr:8686` (Prowlarr server `http://prowlarr:9696`).
- **Sonarr/Radarr/Lidarr**: Download client qBittorrent, host `host.containers.internal`,
  porta 8080, categoria `tv` / `movies` / `music`. Root folder `/data/media/tv`,
  `/data/media/movies`, `/data/media/music`.
- **Bazarr**: Sonarr `sonarr:8989`, Radarr `radarr:7878`.
- **Seerr**: Jellyfin esterno (URL del tuo ambiente Jellyfin), Sonarr `sonarr:8989`,
  Radarr `radarr:7878`.
- **Jellyfin (esterno)**: deve vedere `/data/media` (es. export NFS/SMB dalla seedbox).

## Storage su Backblaze B2

Il servizio OpenRC `rclone-b2` monta `b2:$B2_BUCKET/$B2_PATH` su `/data` all'avvio
(prima di `seedbox`, che non parte se il mount manca). La config rclone viene rigenerata
da `.env` a ogni avvio in `/etc/rclone/seedbox-b2.conf`, quindi dopo aver cambiato le
credenziali basta `doas rc-service rclone-b2 restart` (riavvia anche lo stack).
Log: `/var/log/rclone-b2.log`.

- La chiave B2 deve avere accesso in lettura e scrittura al bucket.
- **Cifratura**: `/data` è un remote rclone `crypt` (`b2crypt:`) sopra `b2:$B2_BUCKET/$B2_PATH`.
  Nomi, cartelle e contenuti su B2 sono cifrati con `B2_CRYPT_PASSWORD`/`B2_CRYPT_PASSWORD2`
  di `.env`, generate da `setup.sh`. **Fanne un backup fuori dal server: senza queste
  chiavi i dati su B2 non si recuperano.** Non vanno chiamate `RCLONE_*`: rclone leggerebbe
  quelle variabili come opzioni proprie. Senza chiavi il mount non parte, così niente
  viene scritto in chiaro. Jellyfin su Fly usa le stesse chiavi (`jellyfin/deploy.sh`).
- `--vfs-cache-mode full`: letture e scritture passano da una cache locale
  (`RCLONE_CACHE_DIR`, max `RCLONE_CACHE_SIZE`, default 4G) e vengono caricate su B2
  dopo 10s.
- qBittorrent scarica in `/incomplete` (`LOCAL_INCOMPLETE`, disco locale) e sposta il
  file finito su `/data/torrents/...`. Lo spazio locale limita quanto puoi scaricare
  in parallelo: con 15 GB di disco tieni pochi download attivi.
- **Niente hardlink su B2**: Sonarr/Radarr/Lidarr ripiegano sulla copia, quindi un
  file ancora in seed occupa spazio due volte (torrents + media). Imposta in qBittorrent
  un limite di ratio/tempo di seed con rimozione, così la copia in `torrents` sparisce.
- **Costi**: il seeding legge da B2 a pezzi (transazioni di classe B + egress oltre la
  quota gratuita). Tieni d'occhio la pagina *Caps & Alerts* di B2.
- Config e database delle app restano in `config/` sul disco locale (SQLite su un
  mount S3 si corromperebbe).
- `config/` non è salvata su B2: per un backup usa per esempio
  `rclone sync config b2:$B2_BUCKET/backup-config` (a stack fermo).

## Readarr

Progetto ritirato upstream (metadati non più disponibili). Per provarlo comunque:
`COMPOSE_PROFILES=readarr` in `.env`, poi `doas rc-service seedbox restart`.

## Verifica

```sh
doas rc-service seedbox status
curl -s http://127.0.0.1:8080/api/v2/app/preferences | grep -o '"current_network_interface":"[^"]*"'   # wg0
curl -s http://127.0.0.1:8080/api/v2/app/preferences | grep -o '"listen_port":[0-9]*'              # porta NAT-PMP
doas podman exec sonarr curl -s https://ipinfo.io/ip                                               # IP VPN
curl -sI -H 'Host: sonarr.casa.local' http://127.0.0.1 | head -1
```
