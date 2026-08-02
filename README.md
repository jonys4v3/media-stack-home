# Media Stack — Jellyfin + *arr auto-hospedado (auto-configurado)

Stack completo en Docker para correr tu propio servidor de medios en casa: películas, series, música, subtítulos, descargas y una UI estilo Netflix para pedir contenido, todo detrás de un único reverse proxy con routing por path — **y configurado solo**, no clickeando en diez UIs distintas.

## ¿Qué incluye?

- **Caddy** — reverse proxy con routing automático por path (un dominio, muchas apps) y HTTPS automático si le das un dominio
- **Jellyfin** — servidor de medios (películas, series, música)
- **Sonarr** / **Radarr** — automatización de bibliotecas (TV, películas)
- **Prowlarr** — gestor de indexers, sincroniza automáticamente hacia Sonarr/Radarr (sin copiar Torznab feeds a mano)
- **FlareSolverr** — proxy que resuelve challenges de Cloudflare para indexers (`:8191`)
- **Bazarr** — subtítulos automáticos
- **qBittorrent** — cliente torrent
- **Jellyseerr** — UI de pedidos (un Netflix para tus usuarios)
- **Wizarr** — invitaciones de usuarios

Mirá [`architecture.excalidraw`](https://github.com/Pelado-Nerdworks/media-stack/blob/main/architecture.excalidraw) para el diagrama completo de topología (abrilo en <https://excalidraw.com>).

## Diagrama del stack

Vista rápida de cómo se conectan las piezas. El pelado apunta al server con dos devices (celu y PC), Caddy rutea por subpath a Jellyfin/Sonarr/Radarr/Bazarr/Prowlarr, Sonarr/Radarr mandan torrents a qBittorrent que escribe en `/data/torrents/`, y Jellyfin escanea la biblioteca final en `/data/media/`.

[![Diagrama del stack](https://github.com/Pelado-Nerdworks/media-stack/raw/main/docs/media-stack-diagram.jpg)](/Pelado-Nerdworks/media-stack/blob/main/docs/media-stack-diagram.jpg)

La estructura interna de carpetas sigue la convención de [TRaSH Guides](https://trash-guides.info/File-and-Folder-Structure/How-to-set-up/Docker/) para que los *arr puedan usar hardlinks y moves atómicos. Ver [docs/DATA_LAYOUT.md](https://github.com/Pelado-Nerdworks/media-stack/blob/main/docs/DATA_LAYOUT.md) para el detalle.

## Requisitos

- Servidor Linux (o VM) con **Docker 24+** y **Docker Compose v2**
- `curl` y `jq` (el script de bootstrap los usa; si falta `jq` y tenés `apt`, se instala solo)
- ~20 GB libres en disco para configs y descargas (más si vas a tener una biblioteca grande)
- Puertos **80**, **443**, **8080** y **8191** abiertos
- Un dominio público (recomendado para HTTPS) o entradas de DNS local — el stack funciona con `http://localhost` también

## Inicio rápido

Antes eran 10 pasos con clicks en 6 UIs distintas. Ahora son 3 comandos:

```bash
git clone https://github.com/Pelado-Nerdworks/media-stack.git
cd media-stack
cp .env.example .env      # opcional: editá usuario/contraseña, indexers, dominio, etc.
bash scripts/bootstrap.sh
```

`bootstrap.sh` hace, en orden:

1. Crea la estructura de `data/` (torrents/media, layout TRaSH Guides).
2. `docker compose up -d` y espera a que cada app esté healthy.
3. Configura la Base URL de cada app por API (Sonarr, Radarr, Prowlarr, Bazarr, Jellyfin) para que respondan en su subpath.
4. Loguea a qBittorrent con la contraseña temporal, la reemplaza por la del `.env`, y crea las categorías de descarga.
5. Configura root folders y el download client (qBittorrent) en Sonarr/Radarr.
6. En Prowlarr: agrega FlareSolverr como proxy, conecta Sonarr/Radarr ("Apps", sync automático) y agrega los indexers públicos que hayas listado en `PROWLARR_INDEXERS`.
7. Conecta Bazarr a Sonarr/Radarr, completa el wizard de Jellyfin (usuario admin + bibliotecas Movies/Series/Music), e intenta conectar Jellyseerr a todo lo anterior.

Es **idempotente**: correlo de nuevo las veces que quieras, no rompe nada que ya esté configurado.

Al final te imprime un resumen con todas las URLs y, si algo no se pudo automatizar (por ejemplo, la API de Jellyseerr cambió de forma en tu versión), te lo dice explícitamente para que lo hagas a mano en esa parte puntual — no hace falta repetir todo el proceso.

### Lo único que sigue siendo manual (y por qué)

- **Trackers privados en Prowlarr**: necesitan tus credenciales personales, no hay forma de automatizar eso sin dártelas nosotros. Los públicos (`PROWLARR_INDEXERS` en `.env`) sí se agregan solos.
- **Wizarr**: crear el usuario admin la primera vez que entrás a `/wizarr`. No tiene una API de setup estable para hacerlo por script.
- **Jellyseerr**, si tu versión cambió los endpoints de setup: el script lo intenta con best-effort y te avisa si falló; conectarlo a mano son 3 pantallas.

| App              | URL                             |
| ---------------- | -------------------------------- |
| Jellyfin         | `http://tu-servidor/jellyfin`   |
| Sonarr           | `http://tu-servidor/sonarr`     |
| Radarr           | `http://tu-servidor/radarr`     |
| Bazarr           | `http://tu-servidor/bazarr`     |
| Prowlarr         | `http://tu-servidor/prowlarr`   |
| Jellyseerr       | `http://tu-servidor/jellyseerr` |
| Wizarr           | `http://tu-servidor/wizarr`     |
| **qBittorrent**  | **`http://tu-servidor:8080`**   |
| **FlareSolverr** | **`http://tu-servidor:8191`**   |

> **Por qué qBittorrent no usa subpath**: emite URLs internas relativas en el HTML que no son compatibles con que un proxy strippee el prefijo. Es la práctica estándar exponerlo en un puerto dedicado. Ver [docs/DATA_LAYOUT.md](https://github.com/Pelado-Nerdworks/media-stack/blob/main/docs/DATA_LAYOUT.md) para más detalle.

## Configuración (todo vive en `.env`)

Copiá `.env.example` como `.env` y editá lo que quieras — nada de esto requiere tocar `docker-compose.yml` a mano:

| Variable | Qué controla |
| --- | --- |
| `CONFIG_DIR`, `DATA_DIR` | Dónde viven configs y medios (default `./config`, `./data`) |
| `PUID`, `PGID` | Usuario/grupo del host con el que corren los containers (`id -u` / `id -g`) |
| `TZ` | Zona horaria de todas las apps |
| `DOMAIN`, `ACME_EMAIL` | Si seteás un dominio real, Caddy pide HTTPS solo vía Let's Encrypt. Vacío = HTTP plano |
| `JELLYFIN_PUBLISHED_URL` | URL pública que Jellyfin anuncia a los clientes |
| `QBIT_USERNAME`, `QBIT_PASSWORD` | Credenciales que `bootstrap.sh` configura en qBittorrent |
| `JELLYFIN_ADMIN_USER`, `JELLYFIN_ADMIN_PASSWORD` | Usuario admin que se crea en el wizard de Jellyfin |
| `PROWLARR_INDEXERS` | Indexers públicos a agregar solos en Prowlarr (coma-separados, nombres exactos del catálogo) |
| `QBIT_CATEGORY_TV`, `QBIT_CATEGORY_MOVIES` | Categorías de descarga que usan Sonarr/Radarr |

### Mover configs/datos a otro disco

```
CONFIG_DIR=/srv/media-stack/config
DATA_DIR=/srv/media-stack/data
```

```bash
rsync -av ./config/ /srv/media-stack/config/
rsync -av ./data/ /srv/media-stack/data/
docker compose down
docker compose up -d
```

`./config/` y `./data/` están en `.gitignore`, así no se filtran datos personales al repo.

### HTTPS

Seteá `DOMAIN=tu-dominio.com` y `ACME_EMAIL=vos@tu-dominio.com` en `.env`, apuntá un registro A de DNS a tu servidor, y `docker compose up -d` — Caddy pide el certificado de Let's Encrypt solo, sin tocar el Caddyfile. Ver la [doc de Caddy](https://caddyserver.com/docs/automatic-https) para el detalle.

## Operaciones diarias

```bash
# Ver qué está corriendo (y si pasó el healthcheck)
docker compose ps

# Ver logs en vivo de una app
docker compose logs -f jellyfin

# Actualizar una imagen
docker compose pull sonarr
docker compose up -d sonarr

# Actualizar todo y re-aplicar configuración (idempotente)
docker compose pull
docker compose up -d
bash scripts/bootstrap.sh

# Frenar el stack (conserva configs y datos)
docker compose down

# Frenar y borrar TODO — configs incluidas (¡destructivo!)
docker compose down -v
```

## Troubleshooting

- **Algo no llegó a "healthy" durante el bootstrap.** Corré `docker compose logs -f <servicio>` para ver por qué, y después `bash scripts/bootstrap.sh` de nuevo — es idempotente, retoma donde falló.
- **La app muestra página en blanco o 404 después de `docker compose up`.** Probablemente el bootstrap no llegó a correr o falló la parte de Base URL. Corré `bash scripts/bootstrap.sh`.
- **qBittorrent no acepta usuario/contraseña del `.env`.** Puede que ya lo hayas cambiado a mano antes. Entrá con esa contraseña o resetealo: `docker compose down qbittorrent && rm -rf config/qbittorrent && docker compose up -d qbittorrent && bash scripts/bootstrap.sh`.
- **Caddy devuelve 502 / no llega a las apps.** Verificá que Caddy esté arriba (`docker compose ps caddy`) y que los demás containers estén en la red `proxy` (lo están por default).
- **Errores de "Permission denied" escribiendo a `/data/torrents` o `/data/media`.** Los valores `PUID`/`PGID` en `.env` no coinciden con tu usuario del host. Actualizalos y `docker compose up -d` de nuevo.
- **"Address already in use" en los puertos 80/443/8080/8191.** Hay otro servicio ocupando esos puertos. Frenalo o cambialos en `docker-compose.yml`.
- **Un indexer con CloudflareChallenge falla constantemente.** Revisá que FlareSolverr aparezca en Prowlarr → Settings → Indexer Proxies, y que el indexer lo tenga asignado en sus Advanced Settings.
- **Prowlarr no encontró un indexer de `PROWLARR_INDEXERS`.** El nombre tiene que ser exacto al del catálogo. Andá a Prowlarr → Add Indexer y copiá el nombre tal cual aparece ahí.

## Estructura del repo

```
media-stack/
├── config/                 # Settings de cada app (ignorado por git)
├── data/                   # Medios + descargas (ignorado por git)
│   ├── torrents/{movies,series,music}/   # staging (escribe qBittorrent)
│   └── media/{movies,series,music}/      # biblioteca final (lee Jellyfin/Bazarr)
├── scripts/
│   ├── init-data-dirs.sh   # crea la estructura de data/ (idempotente)
│   └── bootstrap.sh        # levanta todo y lo configura por API (idempotente)
├── docs/
│   ├── DATA_LAYOUT.md
│   └── INDEXERS.md
├── caddy/Caddyfile
├── docker-compose.yml
├── .env.example
└── README.md
```

## Contribuciones

Pull requests bienvenidos. Mantené los cambios enfocados y actualizá este README cuando agregues o cambies servicios.

## Agradecimientos

- [TRaSH Guides](https://trash-guides.info/) — por la convención de folder structure que seguimos
- [LinuxServer.io](https://docs.linuxserver.io/) — por mantener la mayoría de las imágenes Docker
- El proyecto [Servarr](https://wiki.servarr.com/) (Sonarr, Radarr, Bazarr, Prowlarr)
- [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) — por resolver challenges de Cloudflare
- [Jellyfin](https://jellyfin.org) — por el servidor de medios
- [Jellyseerr](https://github.com/Fallenbagel/jellyseerr) — por la UI de pedidos
- [Wizarr](https://github.com/Wizarrrr/wizarr) — por el sistema de invitaciones
