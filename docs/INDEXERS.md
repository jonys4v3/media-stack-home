# Indexers, Prowlarr y FlareSolverr

Este doc asume que ya corriste `bash scripts/bootstrap.sh` (ver `README.md` → Inicio rápido). Si lo hiciste, esto ya está resuelto para vos:

- FlareSolverr agregado como Indexer Proxy en Prowlarr.
- Sonarr y Radarr conectados como "Apps" en Prowlarr, con sync automático — cualquier indexer que agregues en Prowlarr aparece solo en Sonarr y Radarr, sin copiar Torznab feeds a mano.
- Los indexers públicos listados en `PROWLARR_INDEXERS` (`.env`) ya agregados.

Lo que queda es 100% manual porque necesita tus credenciales personales: **agregar trackers privados**.

## Por qué hablamos en URLs internas

Todos los servicios del stack comparten la red Docker `proxy`. Eso significa que **adentro de la red, los containers se ven por nombre**. Prowlarr le habla a FlareSolverr como `http://flaresolverr:8191/`, y a Sonarr/Radarr como `http://sonarr:8989/sonarr` y `http://radarr:7878/radarr` — nunca sale a Internet para eso.

| Desde | A Prowlarr | A FlareSolverr |
| --- | --- | --- |
| Desde tu navegador | `http://<tu-servidor>/prowlarr` | `http://<tu-servidor>:8191` |
| Desde Prowlarr hacia FlareSolverr | — | `http://flaresolverr:8191/` |

## 1. Agregar un tracker privado

1. Abrí Prowlarr en `http://<tu-servidor>/prowlarr`.
2. `Settings → Indexers → Add Indexer`.
3. Buscá tu tracker (hay cientos en el catálogo). Completá usuario/contraseña o cookie según pida.
4. Si el tracker usa CloudflareChallenge, en la sección de Advanced del indexer poné el Indexer Proxy `FlareSolverr` (ya está creado por el bootstrap).
5. Guardá. **No hace falta hacer nada más** — como Sonarr y Radarr ya están conectados como Apps con `syncLevel: fullSync`, el indexer aparece solo ahí en unos segundos.

## 2. Agregar trackers públicos sin tocar la UI

Si son públicos (no piden cuenta), podés listarlos en `.env` y que `bootstrap.sh` los agregue por vos:

```
PROWLARR_INDEXERS=1337x,The Pirate Bay,YTS,Nyaa.si
```

El nombre tiene que coincidir **exacto** con el catálogo de Prowlarr (`Settings → Indexers → Add Indexer` para ver los nombres disponibles). Si `bootstrap.sh` no encuentra un nombre, te lo avisa al final y lo tenés que agregar a mano una vez.

## 3. Verificar que Sonarr/Radarr recibieron el indexer

`Sonarr/Radarr → Settings → Indexers` — debería aparecer automáticamente con el prefijo `(Prowlarr)`. Si no aparece después de un minuto, revisá en Prowlarr → `Settings → Apps` que la conexión a esa app siga en verde ("Test" pasa OK).

## 4. Troubleshooting

- **Un indexer con CloudflareChallenge falla constantemente.** Confirmá que tenga el Indexer Proxy `FlareSolverr` asignado en sus Advanced Settings dentro de Prowlarr (no en Sonarr/Radarr — eso ya no hace falta, Prowlarr resuelve el challenge antes de pasarle el resultado a los *arr).
- **El indexer no sincroniza a Sonarr/Radarr.** Revisá `Settings → Apps` en Prowlarr: la app tiene que decir `Sync Level: Full Sync`. Si la conexión falla, `bootstrap.sh` no pudo crearla — corré `bash scripts/bootstrap.sh` de nuevo (es idempotente) o creala a mano con `Settings → Apps → Add` apuntando a `http://sonarr:8989/sonarr` / `http://radarr:7878/radarr` con su API key (Settings → General en cada app).
- **FlareSolverr no responde.** `docker compose logs flaresolverr` y verificá `http://<tu-servidor>:8191` devuelve JSON.
