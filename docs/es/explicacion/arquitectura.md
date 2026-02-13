# Arquitectura

## Objetivos de diseño

La plataforma optimiza tres cosas al mismo tiempo:

1. desarrollo local rapido
2. control operativo por funcion
3. baja complejidad operativa

Por eso mantiene OpenResty como unico borde HTTP y usa runtimes de lenguaje por Unix sockets.

## Modelo mental

Cliente HTTP -> OpenResty (`/fn/...`) -> runtime (`python`/`node`/`php`/`rust`) -> handler

En Docker, todo corre dentro del servicio `openresty`, incluyendo procesos runtime.

## Discovery por filesystem (configurable)

No existe `routes.json` estatico. Las funciones se descubren desde un root de filesystem.

Ese root se configura con `FN_FUNCTIONS_ROOT`.

Orden de resolucion:

1. `FN_FUNCTIONS_ROOT`
2. `/app/srv/fn/functions`
3. `$PWD/srv/fn/functions`
4. `/srv/fn/functions`

La lista de runtimes tambien es configurable:

- `FN_RUNTIMES` (CSV, ejemplo `python,node,php,rust`)

El mapeo de sockets es configurable:

- `FN_RUNTIME_SOCKETS` (JSON runtime -> socket URI)
- `FN_SOCKET_BASE_DIR` (base de sockets si no hay mapa)

Precedencia de rutas legacy:

- Si el mismo nombre existe en varios runtimes, `/fn/<name>` resuelve al primer runtime en `FN_RUNTIMES`.
- Si `FN_RUNTIMES` no esta definido, usa orden alfabetico de carpetas runtime.

## Politica por funcion

`fn.config.json` puede definir:

- `invoke.methods`
- `timeout_ms`
- `max_concurrency`
- `max_body_bytes`

Esto evita rigidez global y deja control cerca del owner de la funcion.

## Contrato runtime uniforme

Todos los runtimes comparten el mismo protocolo:

- request: `{ fn, version, event }`
- response: `{ status, headers, body }`

Asi el gateway se mantiene agnostico al lenguaje.

## Seguridad

Controles incluidos:

- proteccion contra path traversal
- proteccion contra escapes por symlink en writes
- masking de secretos (`fn.env.json` con `is_secret=true`) en consola
- permisos de consola por flags (`ui/api/write/local_only`)
- sandbox estricto por funcion habilitado por default (`FN_STRICT_FS=1`)

## Tradeoffs conocidos

- latencia mayor que Lua embebido en algunos casos
- discovery filesystem requiere disciplina de estructura
- auth publica es por funcion (no centralizada por default)

Tradeoff intencional: velocidad local fuerte + control practico.
