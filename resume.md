# Resume — stato della seedbox (2026-10-18)

Appunti per riprendere il lavoro. Dettagli tecnici in `README.md` e `jellyfin/README.md`.

## Com'è fatta

- **Server**: VM Alpine 3.24 (4 vCPU, 2 GB RAM + 4 GB swap). Disco di sistema 15.5 GB
  (`/dev/vda3`) + **disco dati 128 GB** (`/dev/vdb`, ext4, label `seedbox`, montato su
  `/srv/seedbox` via fstab). IP LAN `<ip-vm>` (rete NAT libvirt). WireGuard `wg0`
  (ProtonVPN) in full tunnel: IP pubblico VPN `<ip-vpn>`.
- **Podman rootful** + `docker compose` sul socket `/run/podman/podman.sock`
  (`doas scripts/dc ...` per lo stack `seedbox`, `doas scripts/dc-core ...` per `seedbox-core`). `doas` senza password per `seedbox` (`override-doas.sh`).
- **Servizi OpenRC** (runlevel default): `podman` → `seedbox-core` (core.yaml: NPM, Prowlarr,
  Seerr, pagina di stato; non dipende da /data e resta su) e `rclone-b2` → `seedbox`
  (compose.yaml: qBittorrent, *arr, Bazarr, File Browser; si ferma con il mount), più
  `seedbox-natpmp`, `seedbox-diskguard`, `seedbox-status`. Rete podman `seedbox` condivisa.
- **Storage**: `/data` = rclone **crypt** su `b2:<bucket>/seedbox` (B2 S3, eu-central-003);
  su B2 nomi e contenuti sono cifrati. Sul disco dati locale: download incompleti di
  qBittorrent (`/srv/seedbox/incomplete`) e cache VFS rclone (`/srv/seedbox/rclone-cache`,
  max 100G: il disco dati non ospita più gli incompleti). `rclone-b2` non parte se `/srv/seedbox` non è montato.
- **Download**: tutti scrivono direttamente su `/data` (cartella incompleti disattivata),
  sequenziali; la cache rclone li carica man mano.
- **Protezione disco**: `seedbox-diskguard` ferma i download incompleti sotto 2 GB liberi
  e riavvia solo quelli che ha fermato sopra 4 GB.
- **App** (`*.casa.local` via Nginx Proxy Manager, creati da `scripts/npm-provision.sh`):
  qbittorrent/qbit, prowlarr, sonarr, radarr, lidarr, bazarr, seerr/overseerr,
  fm (File Browser), rclone (pagina di stato), npm; `casa.local` è la dashboard con i link
  e lo stato dei servizi (`home/www`, container `home` nello stack core). Libri: lazylibrarian/ll
  (download) e Audiobookshelf su libri/abs (lettura e ascolto). FlareSolverr rimosso: i siti che bloccano l'IP della VPN
  non li risolveva comunque.
- **Pagina di stato** `rclone.casa.local`: `scripts/rclone-status.sh` (servizio
  `seedbox-status`) scrive ogni 1s `status.json` e ogni 5s `history.json` (1 ora) in
  `/var/lib/seedbox/status`; li serve `busybox httpd` (`status/www`). Dati da API rc di
  rclone (127.0.0.1:5572, password in `/etc/rclone/rc.pass`), /proc, tune2fs, dmesg.
  Mostra anche i nomi dei file in caricamento (richiesto): la pagina non ha login.
- **qBittorrent**: I/O POSIX, file pool 20, gestione automatica torrent di default.
  Categorie: `tv`/`movies`/`music`/`books` → `/data/torrents/...` (per le *arr);
  `film`/`serie`/`musica`/`libri` → direttamente in `/data/media/...`;
  `b2` → `/data/torrents/b2` senza incompleti locali (download sequenziale forzato dal
  disk guard), per torrent più grandi del disco locale.
- **Collegamenti fatti**: Sonarr, Radarr, Lidarr → qBittorrent e → Jellyfin (aggiornamento
  libreria, chiave API di Seerr); Seerr → Sonarr, Radarr; Bazarr → Sonarr, Radarr (it + en);
  LazyLibrarian → qBittorrent (categoria `books`); Prowlarr → Sonarr, Radarr,
  Lidarr, LazyLibrarian (fullSync).
- **Jellyfin** su Fly.io: app `<app-fly>` (ams, 2GB, suspend), https://<app-fly>.fly.dev,
  monta `b2crypt:media` in sola lettura con una chiave B2 read-only. Deploy: `jellyfin/deploy.sh`.

## Segreti (NON nel repo)

- `.env`: chiavi B2 (lettura/scrittura), **`B2_CRYPT_PASSWORD` / `B2_CRYPT_PASSWORD2`**
  (senza di esse i dati su B2 sono persi), password NPM, qBittorrent, File Browser.
- `jellyfin/.env`: chiave B2 read-only, nome app Fly.
- Su Fly gli stessi valori sono *fly secrets* (`fly secrets list -a <app-fly>`).
- `/etc/rclone/rc.pass` (password API rc), generata da `openrc/rclone-b2`.
- `config/` (database e config delle app) è esclusa dal repo e non ha backup.

## Da fare / in sospeso

1. **WireGuard Proton**: NAT-PMP non funziona ("gateway does not support nat-pmp") e alcuni
   indexer bloccano l'IP attuale via Cloudflare. Generare una config WireGuard su un server
   **P2P** con *NAT-PMP* attivo e installarla in `/etc/wireguard/wg0.conf`; poi verificare
   IP, binding di qBittorrent su wg0 e porta in `/var/log/seedbox-natpmp.log`.
2. **Radarr / Lidarr → qBittorrent**: come Sonarr (host `host.containers.internal:8080`,
   password dal `.env`, categorie `movies` / `music`). Si può fare via API.
3. **Indexer** in Prowlarr (scelta dell'utente); si sincronizzano da soli nelle *arr.
4. **Torrent da ~1 TB** (hash `6d78537b…`): in categoria `b2`, fermo. Va avviato e,
   arrivati i metadati, controllato che i singoli file siano molto più piccoli dello spazio
   locale; i file più grandi di ~2 GB non stanno bene in questo schema.
5. **Jellyfin libri**: togliere il plugin Bookshelf (per Jellyfin 10.11, duplica Google
   Books e Comic Vine); creare una chiave Google Books API e metterla nel plugin Google Books
   (ora 429 Too Many Requests dall'IP condiviso di Fly); reinstallare OpenLibrary (per 12);
   abilitare i due provider nella libreria libri e "Sostituisci tutti i metadati".
   Togliere anche AniSearch (10.11) e Folio (10.12, origine sconosciuta); DLNA e NextPVR
   inutili su Fly. Serve una API key Jellyfin per farlo via API.
6. **Jellyfin**: applicare `jellyfin/jellyfin.css` (Dashboard → Branding → Custom CSS);
   login disclaimer «Тварь ли я дрожащая или право имею?».
7. **Collegamenti restanti**: Bazarr → Sonarr/Radarr; Seerr → Jellyfin
   (`https://<app-fly>.fly.dev`) + Sonarr/Radarr; *arr → Connect → Jellyfin.
8. ~~**qBittorrent**: limite di ratio/tempo di seed~~ fatto: niente seed (ratio 0, stop appena finito); Sonarr/Radarr rimuovono i
   torrent importati (su B2 niente hardlink: i file in seed occupano spazio due volte).
9. **Backup**: chiavi di cifratura nel password manager; backup di `config/`
   (es. `rclone sync config b2crypt:backup-config` a stack fermo).
10. **Client**: aggiungere in `/etc/hosts` la riga con tutti i `*.casa.local` (nel README).
11. RAM: lo stack sta stretto in 2 GB (swap ~1.2 GB usato); valutare 4 GB.

## Note utili

- Non chiamare variabili `RCLONE_*` in `.env`: rclone le legge come proprie opzioni
  (è successo con le chiavi crypt).
- nginx in NPM non risolve `host.containers.internal`: per qBittorrent (rete host) si usa
  il gateway della rete `seedbox` (10.89.0.1), calcolato da `npm-provision.sh`.
- Le cartelle vuote non esistono su B2: per renderle persistenti serve un file (`.keep`).
- Prima di riavviare `rclone-b2` aspettare che File Browser abbia finito di ricevere file:
  la coda verso B2 riprende da sola, un caricamento dal browser interrotto no.
- I log in /var/log ruotano con logrotate (`etc/logrotate-seedbox`, anche ogni ora oltre 100 MB):
  rclone in INFO scrive centinaia di righe al secondo ("queuing for upload") perché l'I/O POSIX
  di qBittorrent apre e chiude i file a ogni scrittura.
- Il servizio `podman` di Alpine avvia al boot i container `unless-stopped`: le app su /data
  hanno `restart: on-failure`, podman parte dopo `rclone-b2` (`rc_after`) e la cartella /data
  sotto il mount è immutabile (`chattr +i`). Il 2026-10-18 qBittorrent aveva riempito il disco
  di sistema scrivendo lì prima del mount.
- Tailscale va in modalità iptables (`firewall_mode` in /etc/conf.d/tailscale): in nftables
  rende la tabella nat illeggibile per netavark e i container non partono.
- La busybox `cp -a` non preserva i file sparsi; l'awk di busybox va in overflow con
  `%d` oltre 2^31 (usare `%.0f`); risposte grandi (es. `vfs/queue`) vanno passate a jq
  da file, non come argomento.
- Il suspend di Fly funziona solo con VM ≤ 2GB e senza swap. `fly ssh` può fallire
  sul tunnel WireGuard: `fly machine exec` funziona via API.
- Senza systemd i healthcheck di podman non girano da soli: lo stato `(starting)` in
  `podman ps` è solo estetico.
- Log: `/var/log/rclone-b2.log`, `/var/log/seedbox-natpmp.log`,
  `/var/log/seedbox-diskguard.log`, `/var/log/seedbox-status.log`,
  `doas scripts/dc logs -f <app>`, `~/.fly/bin/fly logs -a <app-fly>`.
