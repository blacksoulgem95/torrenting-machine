# Resume — stato della seedbox (2026-10-18)

Appunti per riprendere il lavoro. Dettagli tecnici in `README.md` e `jellyfin/README.md`.

## Com'è fatta

- **Server**: VM Alpine 3.24 (4 vCPU, 2 GB RAM + 4 GB swap, disco 15.5 GB), IP LAN
  `<ip-vm>` (rete NAT libvirt). WireGuard `wg0` (ProtonVPN) in full tunnel:
  IP pubblico VPN `<ip-vpn>`.
- **Podman rootful** + `docker compose` sul socket `/run/podman/podman.sock`
  (`doas scripts/dc ...`). `doas` senza password per `seedbox` (`override-doas.sh`).
- **Servizi OpenRC** (runlevel default): `podman` → `rclone-b2` → `seedbox` → `seedbox-natpmp`.
- **Storage**: `/data` = rclone **crypt** su `b2:<bucket>/seedbox` (B2 S3, eu-central-003).
  Su B2 nomi e contenuti sono cifrati. Download incompleti di qBittorrent in locale su
  `/srv/seedbox/incomplete`; cache VFS rclone in `/var/cache/rclone` (max 4G).
- **App** (`*.casa.local` via Nginx Proxy Manager, creati da `scripts/npm-provision.sh`):
  qbittorrent/qbit, prowlarr, sonarr, radarr, lidarr, bazarr, seerr/overseerr,
  fm (File Browser), npm. Readarr: solo con `COMPOSE_PROFILES=readarr`. FlareSolverr interno.
- **Jellyfin** su Fly.io: app `<app-fly>` (ams, 2GB, suspend), https://<app-fly>.fly.dev,
  monta `b2crypt:media` in sola lettura con una chiave B2 read-only. Deploy: `jellyfin/deploy.sh`.

## Segreti (NON nel repo)

- `.env`: chiavi B2 (lettura/scrittura), **`B2_CRYPT_PASSWORD` / `B2_CRYPT_PASSWORD2`**
  (senza di esse i dati su B2 sono persi), password NPM, qBittorrent, File Browser.
- `jellyfin/.env`: chiave B2 read-only, nome app Fly.
- Su Fly gli stessi valori sono *fly secrets* (`fly secrets list -a <app-fly>`).
- `config/` (database e config delle app) è esclusa dal repo e non ha backup:
  vedi "Da fare".

## Da fare / in sospeso

1. **URGENTE — disco locale quasi pieno.** Restavano 5.4 GB liberi con 3.5 GB già in
   `/srv/seedbox/incomplete` e download attivi da 16 GB, 6 GB e 3 GB. C'è anche un torrent
   da ~1 TB (probabilmente quello senza metadati, nome = hash `1ea41dd8…`), che **non può
   stare** su questa VM: incompleti e cache rclone stanno sul disco di sistema.
   Proposte (in attesa di decisione):
   - mettere in pausa i download grandi / limitare i download attivi;
   - watchdog che mette in pausa tutto in qBittorrent sotto i 2 GB liberi;
   - aggiungere alla VM un disco dedicato (~1.1 TB per un torrent da 1 TB) e spostarci
     `LOCAL_INCOMPLETE` e `RCLONE_CACHE_DIR`;
   - in alternativa scaricare solo alcuni file del torrent, a blocchi.
2. **NAT-PMP non funziona**: `/var/log/seedbox-natpmp.log` dice "gateway does not support
   nat-pmp". Rigenerare la config WireGuard Proton su un server P2P con *NAT-PMP* attivo
   (`/etc/wireguard/wg0.conf`). qBittorrent ora è sulla porta 6881, senza porta aperta.
3. **Backup**: chiavi di cifratura nel password manager (in corso); backup di `config/`
   (es. `rclone sync config b2crypt:backup-config` a stack fermo).
4. **Jellyfin**: completare il wizard; librerie `/media/movies`, `/media/tv`, `/media/music`;
   applicare `jellyfin/jellyfin.css` (Dashboard → Branding → Custom CSS, si può fare via
   API dopo il wizard); login disclaimer «Тварь ли я дрожащая или право имею?».
5. **Collegamenti tra app** (vedi README): Prowlarr → *arr + FlareSolverr; *arr → qBittorrent
   (`host.containers.internal:8080`, categorie tv/movies/music/books); Bazarr; Seerr →
   Jellyfin (`https://<app-fly>.fly.dev`) + Sonarr/Radarr; *arr → Connect → Jellyfin.
6. **qBittorrent**: impostare limite di ratio/tempo di seed con rimozione (su B2 niente
   hardlink: i file in seed occupano spazio due volte).
7. **Client**: aggiungere in `/etc/hosts` la riga con tutti i `*.casa.local` (nel README).
8. RAM: lo stack sta stretto in 2 GB; valutare di portare la VM a 4 GB.

## Note utili

- Non chiamare variabili `RCLONE_*` in `.env`: rclone le legge come proprie opzioni
  (è successo con le chiavi crypt).
- nginx in NPM non risolve `host.containers.internal`: per qBittorrent (rete host) si usa
  il gateway della rete `seedbox` (10.89.0.1), calcolato da `npm-provision.sh`.
- Il suspend di Fly funziona solo con VM ≤ 2GB e senza swap.
- Senza systemd i healthcheck di podman non girano da soli: lo stato `(starting)` in
  `podman ps` è solo estetico.
- Log: `/var/log/rclone-b2.log`, `/var/log/seedbox-natpmp.log`,
  `doas scripts/dc logs -f <app>`, `~/.fly/bin/fly logs -a <app-fly>`.
