#!/usr/bin/env bash
# bootstrap.sh — deja todo el stack andando y conectado entre sí con un solo comando.
#
# Reemplaza los pasos manuales que antes había que hacer clickeando en cada UI:
#   - Base URL / UrlBase de cada app (antes: sed a mano sobre XML)
#   - Root folders de Sonarr/Radarr
#   - Download client (qBittorrent) en Sonarr/Radarr
#   - Contraseña y save path de qBittorrent (antes: sacar la temporal de los logs)
#   - Indexers públicos + FlareSolverr + sync a Sonarr/Radarr en Prowlarr
#   - Conexión Bazarr → Sonarr/Radarr
#   - Setup wizard de Jellyfin (usuario admin + bibliotecas)
#   - Conexión Jellyseerr → Jellyfin/Sonarr/Radarr (best-effort, ver abajo)
#
# Lo único que sigue siendo 100% manual (no hay forma de automatizarlo sin tus
# credenciales personales o sin una API estable):
#   - Login a trackers PRIVADOS en Prowlarr (los públicos sí se agregan solos)
#   - Wizarr: crear el usuario admin la primera vez que entrás a /wizarr
#
# Uso:
#   cp .env.example .env   # editá lo que quieras, o dejalo con los defaults
#   bash scripts/bootstrap.sh
#
# Idempotente: se puede correr de nuevo sin romper nada si algo falló a mitad.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; FAILURES+=("$*"); }
err()  { printf "${RED}[x]${NC} %s\n" "$*"; }
die()  { err "$*"; exit 1; }

FAILURES=()

# ─── 0. Pre-flight ─────────────────────────────────────────────────────────────

[ -f .env ] || { log "No hay .env, copiando .env.example → .env (defaults)"; cp .env.example .env; }
set -a; source .env; set +a

command -v docker >/dev/null || die "Falta docker. Instalalo antes de seguir."
docker compose version >/dev/null 2>&1 || die "Falta 'docker compose' (v2). Instalalo antes de seguir."
command -v curl >/dev/null || die "Falta curl. En Debian/Ubuntu: sudo apt-get install -y curl"
if ! command -v jq >/dev/null; then
  warn "Falta jq, es necesario para parsear las respuestas de las APIs."
  if command -v apt-get >/dev/null && [ "$(id -u)" = "0" -o -n "${SUDO_USER:-}" ]; then
    log "Instalando jq con apt-get..."
    (sudo apt-get update -qq && sudo apt-get install -y -qq jq) || die "No pude instalar jq. Instalalo a mano: sudo apt-get install -y jq"
  else
    die "Instalá jq a mano (sudo apt-get install -y jq / brew install jq) y volvé a correr este script."
  fi
fi

QBIT_USERNAME="${QBIT_USERNAME:-admin}"
QBIT_PASSWORD="${QBIT_PASSWORD:-changeme-strong-password}"
JELLYFIN_ADMIN_USER="${JELLYFIN_ADMIN_USER:-admin}"
JELLYFIN_ADMIN_PASSWORD="${JELLYFIN_ADMIN_PASSWORD:-changeme-strong-password}"
QBIT_CATEGORY_TV="${QBIT_CATEGORY_TV:-tv-sonarr}"
QBIT_CATEGORY_MOVIES="${QBIT_CATEGORY_MOVIES:-radarr}"
PROWLARR_INDEXERS="${PROWLARR_INDEXERS:-}"

# ─── 1. Estructura de datos + stack arriba ─────────────────────────────────────

log "============================================"
log "  1/6 · Estructura de datos y stack"
log "============================================"
DATA_DIR="${DATA_DIR:-./data}" bash scripts/init-data-dirs.sh

log "docker compose up -d"
docker compose up -d

wait_healthy() {
  local container="$1" timeout="${2:-180}"
  for i in $(seq 1 "$timeout"); do
    local status
    status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container" 2>/dev/null || echo "missing")
    [ "$status" = "healthy" ] && return 0
    [ "$status" = "no-healthcheck" ] && return 0
    [ "$status" = "missing" ] && { sleep 2; continue; }
    sleep 1
  done
  return 1
}

log "Esperando healthchecks (puede tardar ~1 min en el primer boot)..."
for c in caddy prowlarr flaresolverr sonarr radarr bazarr qbittorrent jellyfin jellyseerr wizarr; do
  if wait_healthy "$c" 200; then
    log "  ${c}: OK"
  else
    warn "  ${c}: no llegó a 'healthy' a tiempo — revisá 'docker compose logs ${c}'"
  fi
done

# ─── 2. Base URLs (UrlBase / BaseUrl) por API, no por sed ──────────────────────

log "============================================"
log "  2/6 · Base URLs (subpaths)"
log "============================================"

get_arr_apikey() {
  # Sonarr/Radarr/Prowlarr guardan la key en /config/config.xml
  local container="$1"
  docker exec "$container" sh -c "grep -oP '(?<=<ApiKey>)[^<]+' /config/config.xml 2>/dev/null" 2>/dev/null || true
}

set_urlbase_via_api() {
  # Sonarr (v3) y Radarr (v3) y Prowlarr (v1) exponen /config/host con "urlBase"
  local name="$1" container="$2" port="$3" api="$4" apikey="$5" urlbase="$6"
  [ -z "$apikey" ] && { warn "${name}: no encontré API key, salteo Base URL (¿el container arrancó bien?)"; return 1; }
  local current
  current=$(curl -fsS -H "X-Api-Key: ${apikey}" "http://localhost:${port}/api/${api}/config/host" 2>/dev/null)
  [ -z "$current" ] && { warn "${name}: no pude leer config/host, salteo"; return 1; }
  if echo "$current" | jq -e --arg u "$urlbase" '.urlBase == $u' >/dev/null 2>&1; then
    log "${name}: urlBase ya era ${urlbase} (no-op)"
    return 0
  fi
  local id body
  id=$(echo "$current" | jq -r '.id')
  body=$(echo "$current" | jq --arg u "$urlbase" '.urlBase = $u')
  if curl -fsS -X PUT -H "X-Api-Key: ${apikey}" -H "Content-Type: application/json" \
      "http://localhost:${port}/api/${api}/config/host/${id}" -d "$body" >/dev/null; then
    log "${name}: urlBase seteado a ${urlbase}"
  else
    warn "${name}: falló el PUT a config/host"
  fi
}

SONARR_KEY=$(get_arr_apikey sonarr)
RADARR_KEY=$(get_arr_apikey radarr)
PROWLARR_KEY=$(get_arr_apikey prowlarr)

set_urlbase_via_api "Sonarr" sonarr 8989 v3 "$SONARR_KEY" /sonarr
set_urlbase_via_api "Radarr" radarr 7878 v3 "$RADARR_KEY" /radarr
set_urlbase_via_api "Prowlarr" prowlarr 9696 v1 "$PROWLARR_KEY" /prowlarr

# Bazarr: config.yaml (no tiene endpoint estable de host/urlbase pre-auth)
docker exec bazarr bash -c '
  path="/config/config/config.yaml"
  for i in $(seq 1 60); do [ -f "$path" ] && break; sleep 1; done
  if grep -qE "^  base_url: /bazarr" "$path" 2>/dev/null; then
    echo "  Bazarr base_url ya estaba en /bazarr (no-op)"
  elif grep -qE "^  base_url:" "$path" 2>/dev/null; then
    sed -i "s|^  base_url:.*|  base_url: /bazarr|" "$path"
    echo "  Bazarr base_url actualizado a /bazarr"
  else
    warn_msg="  WARN: no encontré \"base_url:\" bajo la sección general de Bazarr; revisar manualmente"
    echo "$warn_msg"
  fi
' 2>&1 | sed 's/^/  /'

# Jellyfin: network.xml puede no tener <BaseUrl>
docker exec jellyfin bash -c '
  path="/config/data/network.xml"
  [ -f "$path" ] || path="/config/network.xml"
  for i in $(seq 1 60); do [ -f "$path" ] && break; sleep 1; done
  if grep -q "<BaseUrl>/jellyfin</BaseUrl>" "$path" 2>/dev/null; then
    echo "  Jellyfin BaseUrl ya estaba en /jellyfin (no-op)"
  elif grep -q "<BaseUrl></BaseUrl>" "$path" 2>/dev/null; then
    sed -i "s|<BaseUrl></BaseUrl>|<BaseUrl>/jellyfin</BaseUrl>|" "$path"
    echo "  Jellyfin BaseUrl actualizado a /jellyfin"
  elif [ -f "$path" ]; then
    sed -i "s|</NetworkConfiguration>|  <BaseUrl>/jellyfin</BaseUrl>\n</NetworkConfiguration>|" "$path"
    echo "  Jellyfin BaseUrl insertado (no existía el tag)"
  else
    echo "  WARN: no encontré network.xml de Jellyfin; revisar manualmente"
  fi
' 2>&1 | sed 's/^/  /'

log "Reiniciando apps para que tomen las nuevas Base URLs..."
docker compose restart sonarr radarr prowlarr bazarr jellyfin >/dev/null
for c in sonarr radarr prowlarr bazarr jellyfin; do wait_healthy "$c" 120 || warn "${c}: no volvió healthy tras el restart"; done

# ─── 3. qBittorrent: credenciales, save path y categorías ──────────────────────

log "============================================"
log "  3/6 · qBittorrent"
log "============================================"

QBIT_COOKIE=$(mktemp)
trap 'rm -f "$QBIT_COOKIE"' EXIT

qbit_login() {
  local user="$1" pass="$2"
  curl -fsS -c "$QBIT_COOKIE" -X POST "http://localhost:8080/api/v2/auth/login" \
    --data-urlencode "username=${user}" --data-urlencode "password=${pass}" \
    -H "Referer: http://localhost:8080" >/dev/null 2>&1
}

# Primero probamos con las credenciales ya deseadas (por si ya se corrió antes).
if qbit_login "$QBIT_USERNAME" "$QBIT_PASSWORD" && curl -fsS -b "$QBIT_COOKIE" "http://localhost:8080/api/v2/app/version" | grep -q .; then
  log "qBittorrent: ya estaba configurado con las credenciales del .env"
else
  QBIT_TEMP_PASS=$(docker logs qbittorrent 2>&1 | grep -i "temporary password" | tail -1 | sed -E 's/.*password[^:]*:\s*//i' | tr -d '\r')
  if [ -z "$QBIT_TEMP_PASS" ]; then
    warn "qBittorrent: no encontré la contraseña temporal en los logs. Configuralo a mano una vez (docker logs qbittorrent | grep -i temporary)."
  else
    log "qBittorrent: encontré la contraseña temporal en los logs, logueando..."
    if qbit_login admin "$QBIT_TEMP_PASS"; then
      curl -fsS -b "$QBIT_COOKIE" -X POST "http://localhost:8080/api/v2/app/setPreferences" \
        -H "Referer: http://localhost:8080" \
        --data-urlencode "json={\"web_ui_username\":\"${QBIT_USERNAME}\",\"web_ui_password\":\"${QBIT_PASSWORD}\",\"save_path\":\"/data/torrents\"}" >/dev/null \
        && log "qBittorrent: usuario/contraseña y save path configurados" \
        || warn "qBittorrent: falló setPreferences"
      qbit_login "$QBIT_USERNAME" "$QBIT_PASSWORD" >/dev/null 2>&1
    else
      warn "qBittorrent: no pude loguear con la contraseña temporal (¿ya la habías cambiado a mano?)"
    fi
  fi
fi

for cat_pair in "${QBIT_CATEGORY_TV}:/data/torrents/series" "${QBIT_CATEGORY_MOVIES}:/data/torrents/movies"; do
  cat="${cat_pair%%:*}"; save="${cat_pair##*:}"
  curl -fsS -b "$QBIT_COOKIE" -X POST "http://localhost:8080/api/v2/torrents/createCategory" \
    -H "Referer: http://localhost:8080" \
    --data-urlencode "category=${cat}" --data-urlencode "savePath=${save}" >/dev/null 2>&1
  log "qBittorrent: categoría '${cat}' asegurada (savePath=${save})"
done

# ─── 4. Sonarr/Radarr: root folders + download client ──────────────────────────

log "============================================"
log "  4/6 · Root folders y download client"
log "============================================"

ensure_rootfolder() {
  local name="$1" port="$2" apikey="$3" path="$4"
  [ -z "$apikey" ] && { warn "${name}: sin API key, salteo root folder"; return; }
  local existing
  existing=$(curl -fsS -H "X-Api-Key: ${apikey}" "http://localhost:${port}/api/v3/rootfolder" | jq -r --arg p "$path" '.[] | select(.path == $p) | .path')
  if [ "$existing" = "$path" ]; then
    log "${name}: root folder ${path} ya existía (no-op)"
  else
    curl -fsS -X POST -H "X-Api-Key: ${apikey}" -H "Content-Type: application/json" \
      "http://localhost:${port}/api/v3/rootfolder" -d "{\"path\": \"${path}\"}" >/dev/null \
      && log "${name}: root folder ${path} creado" \
      || warn "${name}: no pude crear el root folder ${path}"
  fi
}

ensure_rootfolder "Sonarr" 8989 "$SONARR_KEY" "/data/media/series"
ensure_rootfolder "Radarr" 7878 "$RADARR_KEY" "/data/media/movies"

ensure_downloadclient() {
  local name="$1" port="$2" apikey="$3" category_field="$4" category_val="$5"
  [ -z "$apikey" ] && { warn "${name}: sin API key, salteo download client"; return; }
  local existing
  existing=$(curl -fsS -H "X-Api-Key: ${apikey}" "http://localhost:${port}/api/v3/downloadclient" | jq -r '.[] | select(.implementation == "QBittorrent") | .id' | head -1)
  if [ -n "$existing" ]; then
    log "${name}: download client qBittorrent ya existía (no-op)"
    return
  fi
  local body
  body=$(jq -n \
    --arg cf "$category_field" --arg cv "$category_val" \
    --arg user "$QBIT_USERNAME" --arg pass "$QBIT_PASSWORD" \
    '{
      enable: true, protocol: "torrent", priority: 1,
      name: "qBittorrent", implementation: "QBittorrent",
      configContract: "QBittorrentSettings",
      fields: [
        {name: "host", value: "qbittorrent"},
        {name: "port", value: 8080},
        {name: "username", value: $user},
        {name: "password", value: $pass},
        {name: $cf, value: $cv},
        {name: "useSsl", value: false}
      ]
    }')
  curl -fsS -X POST -H "X-Api-Key: ${apikey}" -H "Content-Type: application/json" \
    "http://localhost:${port}/api/v3/downloadclient" -d "$body" >/dev/null \
    && log "${name}: download client qBittorrent configurado" \
    || warn "${name}: no pude crear el download client (revisá usuario/clave de qBittorrent)"
}

ensure_downloadclient "Sonarr" 8989 "$SONARR_KEY" "tvCategory" "$QBIT_CATEGORY_TV"
ensure_downloadclient "Radarr" 7878 "$RADARR_KEY" "movieCategory" "$QBIT_CATEGORY_MOVIES"

# ─── 5. Prowlarr: FlareSolverr + Apps (Sonarr/Radarr) + indexers públicos ──────

log "============================================"
log "  5/6 · Prowlarr (indexers, FlareSolverr, sync)"
log "============================================"

if [ -z "$PROWLARR_KEY" ]; then
  warn "Prowlarr: sin API key, salteo toda la sección"
else
  # FlareSolverr como Indexer Proxy
  existing=$(curl -fsS -H "X-Api-Key: ${PROWLARR_KEY}" "http://localhost:9696/api/v1/indexerproxy" | jq -r '.[] | select(.implementation=="FlareSolverr") | .id' | head -1)
  if [ -z "$existing" ]; then
    body=$(jq -n '{
      name: "FlareSolverr", implementation: "FlareSolverr", configContract: "FlareSolverrSettings",
      fields: [{name:"host", value:"http://flaresolverr:8191/"}, {name:"requestTimeout", value:60}], tags: []
    }')
    curl -fsS -X POST -H "X-Api-Key: ${PROWLARR_KEY}" -H "Content-Type: application/json" \
      "http://localhost:9696/api/v1/indexerproxy" -d "$body" >/dev/null \
      && log "Prowlarr: FlareSolverr agregado como Indexer Proxy" \
      || warn "Prowlarr: no pude agregar FlareSolverr"
  else
    log "Prowlarr: FlareSolverr ya estaba configurado (no-op)"
  fi

  # Apps: Sonarr y Radarr (sync automático de indexers, sin copiar Torznab a mano)
  ensure_prowlarr_app() {
    local name="$1" impl="$2" port="$3" apikey="$4"
    [ -z "$apikey" ] && { warn "Prowlarr: sin API key de ${name}, salteo la app"; return; }
    local existing
    existing=$(curl -fsS -H "X-Api-Key: ${PROWLARR_KEY}" "http://localhost:9696/api/v1/applications" | jq -r --arg i "$impl" '.[] | select(.implementation==$i) | .id' | head -1)
    if [ -n "$existing" ]; then
      log "Prowlarr: app ${name} ya estaba conectada (no-op)"
      return
    fi
    local body
    body=$(jq -n --arg name "$name" --arg impl "$impl" --arg url "http://${impl,,}:${port}/${impl,,}" --arg key "$apikey" '{
      name: $name, implementation: $impl, configContract: ($impl + "Settings"), syncLevel: "fullSync",
      fields: [{name:"prowlarrUrl", value:"http://prowlarr:9696/prowlarr"}, {name:"baseUrl", value:$url}, {name:"apiKey", value:$key}]
    }')
    curl -fsS -X POST -H "X-Api-Key: ${PROWLARR_KEY}" -H "Content-Type: application/json" \
      "http://localhost:9696/api/v1/applications" -d "$body" >/dev/null \
      && log "Prowlarr: app ${name} conectada (sync automático activado)" \
      || warn "Prowlarr: no pude conectar la app ${name}"
  }
  ensure_prowlarr_app "Sonarr" "Sonarr" 8989 "$SONARR_KEY"
  ensure_prowlarr_app "Radarr" "Radarr" 7878 "$RADARR_KEY"

  # Indexers públicos listados en PROWLARR_INDEXERS (coma-separados)
  if [ -n "$PROWLARR_INDEXERS" ]; then
    SCHEMA=$(curl -fsS -H "X-Api-Key: ${PROWLARR_KEY}" "http://localhost:9696/api/v1/indexer/schema")
    IFS=',' read -ra NAMES <<< "$PROWLARR_INDEXERS"
    for raw_name in "${NAMES[@]}"; do
      name=$(echo "$raw_name" | sed 's/^ *//;s/ *$//')
      [ -z "$name" ] && continue
      already=$(curl -fsS -H "X-Api-Key: ${PROWLARR_KEY}" "http://localhost:9696/api/v1/indexer" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -1)
      if [ -n "$already" ]; then
        log "Prowlarr: indexer '${name}' ya estaba agregado (no-op)"
        continue
      fi
      def=$(echo "$SCHEMA" | jq --arg n "$name" '[.[] | select(.name == $n)] | first')
      if [ "$def" = "null" ] || [ -z "$def" ]; then
        warn "Prowlarr: no encontré un indexer llamado '${name}' en el catálogo. Agregalo a mano desde la UI (Settings → Indexers) — el nombre tiene que coincidir exacto con el catálogo."
        continue
      fi
      body=$(echo "$def" | jq '.enable = true | .appProfileId = 1 | .priority = 25 | .tags = []')
      curl -fsS -X POST -H "X-Api-Key: ${PROWLARR_KEY}" -H "Content-Type: application/json" \
        "http://localhost:9696/api/v1/indexer" -d "$body" >/dev/null \
        && log "Prowlarr: indexer '${name}' agregado" \
        || warn "Prowlarr: no pude agregar el indexer '${name}'"
    done
  else
    log "PROWLARR_INDEXERS vacío en .env — agregá tus trackers a mano desde /prowlarr (una sola vez; se sincronizan solos a Sonarr/Radarr)."
  fi
fi

# ─── 6. Bazarr, Jellyfin y Jellyseerr ───────────────────────────────────────────

log "============================================"
log "  6/6 · Bazarr, Jellyfin, Jellyseerr"
log "============================================"

# --- Bazarr: conectar Sonarr/Radarr (edita config.yaml, Bazarr lo relee solo) ---
if [ -n "$SONARR_KEY" ] && [ -n "$RADARR_KEY" ]; then
  docker exec bazarr python3 - "$SONARR_KEY" "$RADARR_KEY" <<'PYEOF' 2>&1 | sed 's/^/  /'
import sys, yaml
path = "/config/config/config.yaml"
sonarr_key, radarr_key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        cfg = yaml.safe_load(f) or {}
except FileNotFoundError:
    print("WARN: no existe config.yaml de Bazarr todavia")
    sys.exit(0)

cfg.setdefault("general", {})
cfg["general"]["use_sonarr"] = True
cfg["general"]["use_radarr"] = True

cfg.setdefault("sonarr", {})
cfg["sonarr"].update({"ip": "sonarr", "port": 8989, "base_url": "/sonarr", "apikey": sonarr_key, "ssl": False})

cfg.setdefault("radarr", {})
cfg["radarr"].update({"ip": "radarr", "port": 7878, "base_url": "/radarr", "apikey": radarr_key, "ssl": False})

with open(path, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False)
print("Bazarr: conectado a Sonarr y Radarr")
PYEOF
  docker compose restart bazarr >/dev/null
  wait_healthy bazarr 120 || warn "Bazarr: no volvió healthy tras conectar Sonarr/Radarr"
else
  warn "Bazarr: falta API key de Sonarr o Radarr, no lo conecté"
fi

# --- Jellyfin: completar wizard (usuario admin) sin abrir el navegador ---
JF="http://localhost:8096"
wizard_done=$(curl -fsS "${JF}/System/Info/Public" 2>/dev/null | jq -r '.StartupWizardCompleted // false')
if [ "$wizard_done" = "true" ]; then
  log "Jellyfin: el wizard ya estaba completado (no-op)"
else
  curl -fsS -X POST "${JF}/Startup/Configuration" -H "Content-Type: application/json" \
    -d '{"UICulture":"es-AR","MetadataCountryCode":"AR","PreferredMetadataLanguage":"es"}' >/dev/null
  curl -fsS -X POST "${JF}/Startup/User" -H "Content-Type: application/json" \
    -d "{\"Name\": \"${JELLYFIN_ADMIN_USER}\", \"Password\": \"${JELLYFIN_ADMIN_PASSWORD}\"}" >/dev/null
  curl -fsS -X POST "${JF}/Startup/RemoteAccess" -H "Content-Type: application/json" \
    -d '{"EnableRemoteAccess": true, "EnableAutomaticPortMapping": false}' >/dev/null
  curl -fsS -X POST "${JF}/Startup/Complete" >/dev/null \
    && log "Jellyfin: wizard completado, usuario admin '${JELLYFIN_ADMIN_USER}' creado" \
    || warn "Jellyfin: falló completar el wizard — entrá a /jellyfin y hacelo a mano una vez"
fi

JF_TOKEN=$(curl -fsS -X POST "${JF}/Users/AuthenticateByName" \
  -H "Content-Type: application/json" \
  -H 'X-Emby-Authorization: MediaBrowser Client="bootstrap", Device="bootstrap", DeviceId="bootstrap", Version="1.0"' \
  -d "{\"Username\": \"${JELLYFIN_ADMIN_USER}\", \"Pw\": \"${JELLYFIN_ADMIN_PASSWORD}\"}" 2>/dev/null | jq -r '.AccessToken // empty')

if [ -n "$JF_TOKEN" ]; then
  ensure_jf_library() {
    local name="$1" kind="$2" path="$3"
    local exists
    exists=$(curl -fsS -H "X-Emby-Token: ${JF_TOKEN}" "${JF}/Library/VirtualFolders" | jq -r --arg n "$name" '.[] | select(.Name==$n) | .Name')
    if [ "$exists" = "$name" ]; then
      log "Jellyfin: biblioteca '${name}' ya existía (no-op)"
    else
      curl -fsS -X POST -H "X-Emby-Token: ${JF_TOKEN}" \
        "${JF}/Library/VirtualFolders?name=${name}&collectionType=${kind}&paths=${path}&refreshLibrary=true" >/dev/null \
        && log "Jellyfin: biblioteca '${name}' creada (${path})" \
        || warn "Jellyfin: no pude crear la biblioteca '${name}'"
    fi
  }
  ensure_jf_library "Movies" "movies" "/data/media/movies"
  ensure_jf_library "Series" "tvshows" "/data/media/series"
  ensure_jf_library "Music" "music" "/data/media/music"
else
  warn "Jellyfin: no pude autenticar para crear las bibliotecas — entrá a /jellyfin y agregalas a mano (Dashboard → Libraries)"
fi

# --- Jellyseerr: best-effort. Su API de setup no es pública/estable, así que
#     si falla no es grave — conectarlo a mano son 3 clicks. ---
JS="http://localhost:5055"
js_body=$(jq -n --arg h jellyfin --arg u "$JELLYFIN_ADMIN_USER" --arg p "$JELLYFIN_ADMIN_PASSWORD" \
  '{hostname: $h, port: 8096, urlBase: "/jellyfin", useSsl: false, email: ($u + "@example.com"), username: $u, password: $p}')
if curl -fsS -X POST "${JS}/api/v1/auth/jellyfin" -H "Content-Type: application/json" -d "$js_body" >/dev/null 2>&1; then
  log "Jellyseerr: conectado a Jellyfin"
  if [ -n "$SONARR_KEY" ]; then
    curl -fsS -X POST "${JS}/api/v1/settings/sonarr" -H "Content-Type: application/json" \
      -d "{\"name\":\"Sonarr\",\"hostname\":\"sonarr\",\"port\":8989,\"apiKey\":\"${SONARR_KEY}\",\"urlBase\":\"/sonarr\",\"activeDirectory\":\"/data/media/series\",\"isDefault\":true}" >/dev/null 2>&1 \
      && log "Jellyseerr: Sonarr conectado" || warn "Jellyseerr: no pude conectar Sonarr (conectalo a mano en Settings)"
  fi
  if [ -n "$RADARR_KEY" ]; then
    curl -fsS -X POST "${JS}/api/v1/settings/radarr" -H "Content-Type: application/json" \
      -d "{\"name\":\"Radarr\",\"hostname\":\"radarr\",\"port\":7878,\"apiKey\":\"${RADARR_KEY}\",\"urlBase\":\"/radarr\",\"activeDirectory\":\"/data/media/movies\",\"isDefault\":true}" >/dev/null 2>&1 \
      && log "Jellyseerr: Radarr conectado" || warn "Jellyseerr: no pude conectar Radarr (conectalo a mano en Settings)"
  fi
else
  warn "Jellyseerr: no pude auto-conectarlo (su API de setup cambia entre versiones). Entrá a /jellyseerr y conectalo a mano — 3 pantallas, 1 minuto."
fi

# ─── Resumen ────────────────────────────────────────────────────────────────────

echo
log "============================================"
log "  Listo. URLs de acceso:"
log "    http://<IP>/jellyfin    → Media server (user: ${JELLYFIN_ADMIN_USER})"
log "    http://<IP>/sonarr      → TV shows"
log "    http://<IP>/radarr      → Movies"
log "    http://<IP>/bazarr      → Subtitles"
log "    http://<IP>/prowlarr    → Indexers"
log "    http://<IP>/jellyseerr  → Requests"
log "    http://<IP>/wizarr      → Invitations (crear admin a mano, 1 vez)"
log "    http://<IP>:8080        → qBittorrent (user: ${QBIT_USERNAME})"
log "    http://<IP>:8191        → FlareSolverr"
log "============================================"

if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo
  warn "Hubo ${#FAILURES[@]} paso(s) que no se pudieron automatizar del todo:"
  for f in "${FAILURES[@]}"; do echo "    - $f"; done
  echo
  log "Correr 'bash scripts/bootstrap.sh' de nuevo es seguro (es idempotente) por si eran problemas de timing."
fi
