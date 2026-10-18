# Jellyfin su Fly.io (libreria da Backblaze B2)

Jellyfin 12.1 su una macchina Fly (`ams`, shared-cpu-2x, 2GB) che monta **in sola
lettura** la libreria cifrata della seedbox (`b2crypt:media`, cioè rclone crypt sopra
`b2:<bucket>/seedbox`) su `/media`. `deploy.sh` legge le chiavi di cifratura
`B2_CRYPT_PASSWORD`/`B2_CRYPT_PASSWORD2` dal `.env` principale e le carica come secrets. È la stessa libreria che
la seedbox riempie. Metadati, utenti e cache rclone (max 5G) stanno sul volume
`jellyfin_data` (`/config`, 10GB).

La macchina si **sospende** quando non c'è traffico e riprende alla prima richiesta.
Il suspend richiede al massimo 2GB di RAM e nessuno swap: non alzare `memory` oltre 2gb
senza passare a `auto_stop_machines = "stop"`.

## 1. Chiave B2 di sola lettura

B2 → *Application Keys* → *Add a New Application Key*:
- bucket: `<bucket>`, type of access: **Read Only**
- non impostare un *file name prefix*: con la cifratura i nomi delle cartelle su B2 cambiano

Copia `keyID` e `applicationKey` in `jellyfin/.env` (da `.env.example`). Puoi usare i
doppi apici attorno ai valori.

## 2. flyctl

```sh
curl -L https://fly.io/install.sh | sh
~/.fly/bin/fly auth login
```

## 3. Deploy

1. Scegli un nome unico per l'app e mettilo in `.env` (`FLY_APP=...`): `deploy.sh` genera
   `fly.toml` da `fly.toml.example` con quel nome e con `B2_BUCKET` del `.env` principale.
2. Lancia `./deploy.sh`. Crea app e volume se mancano, carica `B2_KEY_ID`/`B2_APP_KEY`
   come *fly secrets* (arrivano al container come env al boot, non finiscono
   nell'immagine) e fa il deploy.
3. Apri `https://<app>.fly.dev` e completa il wizard di Jellyfin.

Per cambiare le chiavi: aggiorna `.env` e rilancia `./deploy.sh`, oppure
`fly secrets set B2_APP_KEY=...`, che riavvia la macchina.

## 4. Librerie e collegamenti

- Librerie Jellyfin: `/media/movies`, `/media/tv`, `/media/music` (`/media/books` per i libri).
- Sul mount S3 non arrivano notifiche di file nuovi e la lista delle cartelle si aggiorna
  ogni 5 minuti (`--dir-cache-time`). Per scansioni rapide, in Sonarr/Radarr/Lidarr:
  *Settings → Connect → Jellyfin/Emby* con URL `https://<app>.fly.dev` e una API key di
  Jellyfin (*Dashboard → API Keys*). Tieni attiva anche la scansione periodica.
- Seerr sulla seedbox: *Settings → Jellyfin*, URL `https://<app>.fly.dev`, porta 443, SSL.

## Note

- shared-cpu non regge il transcoding video: usa client che fanno direct play
  (app Jellyfin, Infuse, Kodi) e disattiva il transcoding o limitalo per utente.
- Costi: macchina solo quando è accesa, volume sempre, traffico in uscita Fly verso i
  client, transazioni ed egress B2 (gratuito fino a 3× lo spazio occupato).
- Debug: `fly logs`, `fly ssh console -C "ls /media/movies"`, `fly status`.

## Tema «Delitto e castigo»

`jellyfin.css` è un tema ispirato alla soffitta di Raskol'nikov: giallo della carta da
parati, legno scuro, luce fredda di Pietroburgo e il rosso secco del delitto, con i
caratteri Old Standard TT ed EB Garamond. Incollalo in *Dashboard → Generale → Branding →
Custom CSS* per tutto il server, oppure in *Impostazioni → Display* per un solo utente.
Come «Login disclaimer» ci sta bene: *«Тварь ли я дрожащая или право имею?»*
