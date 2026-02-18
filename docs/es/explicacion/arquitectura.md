# Arquitectura

## Objetivos de diseño

La plataforma optimiza tres cosas al mismo tiempo:

1. desarrollo local rápido
2. control operativo por función
3. baja complejidad operativa

Por eso mantiene OpenResty como único edge HTTP y usa runtimes de lenguaje por Unix sockets.

## Modelo mental

Cliente HTTP -> OpenResty (rutas públicas como `/hello`) -> runtime (`python`/`node`/`php`/`rust`) -> handler

En Docker, todo corre dentro del servicio `openresty`, incluyendo procesos runtime.

## Descubrimiento por filesystem (configurable)

No existe `routes.json` estático. Las funciones se descubren desde un root de filesystem (tu "directorio de funciones").

Convención recomendada: crea un directorio `functions/` en la raíz del repo y apunta FastFN a ese lugar.

Formas comunes de configurar el directorio de funciones:

- `fastfn dev functions`
- `fastfn.json` -> `"functions-dir": "functions"`
- `FN_FUNCTIONS_ROOT=/ruta/absoluta/a/functions`

La lista de runtimes también es configurable:

- `FN_RUNTIMES` (CSV, ejemplo `python,node,php,rust`)

El mapeo de sockets es configurable:

- `FN_RUNTIME_SOCKETS` (JSON runtime -> socket URI)
- `FN_SOCKET_BASE_DIR` (base de sockets si no hay mapa)

Precedencia ante colisiones de rutas:

- Si el mismo nombre existe en varios runtimes, `/<name>` resuelve al primer runtime en `FN_RUNTIMES`.
- Si `FN_RUNTIMES` no está definido, usa orden alfabético de carpetas runtime.

## Politica por funcion

`fn.config.json` puede definir:

- `invoke.methods`
- `timeout_ms`
- `max_concurrency`
- `max_body_bytes`

Esto evita rigidez global y deja control cerca del dueño de la función.

## Contrato runtime uniforme

Todos los runtimes comparten el mismo protocolo:

- request: `{ fn, version, event }`
- response: `{ status, headers, body }`

Así el gateway se mantiene agnóstico al lenguaje.

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
- auth pública es por función (no centralizada por defecto)

Tradeoff intencional: velocidad local fuerte + control práctico.
