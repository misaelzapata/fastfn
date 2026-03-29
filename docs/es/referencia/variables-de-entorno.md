# Variables de entorno

> Estado verificado al **27 de marzo de 2026**.

Esta pagina es un indice practico de las variables `FN_*` que aparecen mas seguido en la documentacion y en el comportamiento real de FastFN.

## Vista rapida

- Complejidad: Referencia
- Tiempo tipico: 10-15 minutos
- Úsala cuando: quieres saber que variables importan y para que sirve cada una
- Resultado: puedes configurar la variable correcta en el lugar correcto sin adivinar

## Variables core de proyecto y ruteo

| Variable | Default | Que controla |
| --- | --- | --- |
| `FN_FUNCTIONS_ROOT` | depende del proyecto | Raiz de funciones y discovery |
| `FN_RUNTIMES` | todos los runtimes habilitados | Que runtimes se consideran disponibles |
| `FN_NAMESPACE_DEPTH` | `3` | Cuanto profundiza el discovery agrupado por runtime |
| `FN_ZERO_CONFIG_IGNORE_DIRS` | vacio | Directorios extra ignorados por zero-config discovery |
| `FN_FORCE_URL` | `0` | Comportamiento global de override de rutas de config |
| `FN_PUBLIC_BASE_URL` | derivada del request | URL canonica de OpenAPI |
| `FN_OPENAPI_INCLUDE_INTERNAL` | `0` | Si `/_fn/*` aparece en OpenAPI |
| `FN_HOT_RELOAD` | `1` | Habilita hot reload en `dev` y `run` |

## Daemons, sockets y wiring de runtime

| Variable | Default | Que controla |
| --- | --- | --- |
| `FN_RUNTIME_DAEMONS` | uno por runtime | Cuantos daemons externos arrancar |
| `FN_RUNTIME_SOCKETS` | sockets generados | Mapa explicito de sockets por runtime |
| `FN_SOCKET_BASE_DIR` | default interno | Raiz para sockets generados |
| `FN_RUNTIME_LOG_FILE` | vacio | Archivo usado para capturar logs del runtime |
| `FN_MAX_FRAME_BYTES` | `2097152` | Maximo tamano de frame aceptado por socket |
| `FN_*_BIN` | default del runtime | Binario del host usado por un runtime o tool |

Overrides de binarios comunes:

- `FN_OPENRESTY_BIN`
- `FN_DOCKER_BIN`
- `FN_PYTHON_BIN`
- `FN_NODE_BIN`
- `FN_NPM_BIN`
- `FN_PHP_BIN`
- `FN_COMPOSER_BIN`
- `FN_CARGO_BIN`
- `FN_GO_BIN`

## Variables de seguridad de runtime

| Variable | Default | Que controla |
| --- | --- | --- |
| `FN_STRICT_FS` | `1` | Sandboxing de filesystem para handlers |
| `FN_STRICT_FS_ALLOW` | vacio | Raices extra permitidas en strict fs |
| `FN_PREINSTALL_PY_DEPS_ON_START` | `1` | Preinstala deps Python antes de servir |
| `FN_AUTO_INFER_PY_DEPS` | `1` | Infiere deps Python desde imports |
| `FN_PY_INFER_BACKEND` | `native` | Backend de inferencia Python (`native`, `pipreqs`) |
| `FN_AUTO_INFER_WRITE_MANIFEST` | `1` | Escribe manifests inferidos |
| `FN_AUTO_INFER_STRICT` | `1` | Hace mas estricta la inferencia |
| `FN_PY_RUNTIME_WORKER_POOL` | `1` | Habilita worker pool persistente de Python |
| `FN_GO_RUNTIME_WORKER_POOL` | `1` | Habilita worker pool persistente de Go |
| `FN_NODE_RUNTIME_PROCESS_POOL` | `1` | Habilita worker pool persistente de Node |
| `FN_NODE_INFER_BACKEND` | `native` | Backend de inferencia Node (`native`, `detective`, `require-analyzer`) |

## Variables de consola y admin

| Variable | Default | Que controla |
| --- | --- | --- |
| `FN_UI_ENABLED` | `0` | Disponibilidad de la UI de consola |
| `FN_CONSOLE_API_ENABLED` | `1` | Disponibilidad de la API de consola |
| `FN_CONSOLE_WRITE_ENABLED` | `0` | Operaciones de escritura de consola |
| `FN_CONSOLE_LOCAL_ONLY` | `1` | Guard de acceso solo local |
| `FN_ADMIN_TOKEN` | vacio | Token override de admin |
| `FN_CONSOLE_LOGIN_ENABLED` | `0` | Pantalla de login de la consola |
| `FN_CONSOLE_LOGIN_API` | `0` | Si el login tambien protege la API de consola |
| `FN_CONSOLE_LOGIN_USERNAME` | vacio | Usuario de login |
| `FN_CONSOLE_LOGIN_PASSWORD_HASH` | vacio | Hash recomendado de login (`pbkdf2-sha256:<iterations>:<salt_hex>:<digest_hex>`) |
| `FN_CONSOLE_LOGIN_PASSWORD_HASH_FILE` | vacio | Archivo que contiene el hash de login |
| `FN_CONSOLE_LOGIN_PASSWORD` | vacio | Fallback legacy de password en texto plano |
| `FN_CONSOLE_LOGIN_PASSWORD_FILE` | vacio | Archivo que contiene el password legacy en texto plano |
| `FN_CONSOLE_SESSION_SECRET` | vacio | Secret para cookies de sesion firmadas |
| `FN_CONSOLE_SESSION_SECRET_FILE` | vacio | Archivo que contiene el secret de sesion firmado |
| `FN_CONSOLE_SESSION_TTL_S` | `43200` | Vida util de la cookie de sesion |
| `FN_CONSOLE_LOGIN_RATE_LIMIT_MAX` | `5` | Maximo de intentos de login por ventana |
| `FN_CONSOLE_LOGIN_RATE_LIMIT_WINDOW_S` | `300` | Ventana de rate limit de login en segundos |
| `FN_CONSOLE_RATE_LIMIT_MAX` | `120` | Maximo de requests de lectura/UI por ventana |
| `FN_CONSOLE_RATE_LIMIT_WINDOW_S` | `60` | Ventana general de rate limit de consola |
| `FN_CONSOLE_WRITE_RATE_LIMIT_MAX` | `30` | Maximo de requests admin/write por ventana |

## Assets y helpers de discovery

| Variable | Default | Que controla |
| --- | --- | --- |
| `FN_MAX_ASSET_BYTES` | `33554432` | Tamano maximo servido desde memoria |
| `FN_HOT_RELOAD_WATCHDOG` | `0` o default del runtime | Modo watchdog para dev |
| `FN_HOT_RELOAD_WATCHDOG_POLL` | default del runtime | Intervalo de polling del watchdog |
| `FN_HOT_RELOAD_DEBOUNCE_MS` | default del runtime | Debounce de eventos de reload |

## Notas

- Algunas variables las lee el CLI, otras el gateway y otras los daemons de runtime.
- El prefijo `FN_*` no significa la misma capa en todos los casos.
- Si una variable no hace nada, revisa que proceso la esta leyendo.
- Para login de consola, PBKDF2 es el formato de hash recomendado; `sha256:<hex>` queda aceptado solo como formato legacy de compatibilidad.
- Los backends de inferencia son opcionales. Los manifiestos explícitos siguen siendo más rápidos y más predecibles que invocar `pipreqs`, `detective` o `require-analyzer`.

## Enlaces relacionados

- [Referencia de fastfn.json](./config-fastfn.md)
- [Referencia completa de config](./fn-config-completo.md)
- [Consola y administracion](../como-hacer/consola-admin.md)
- [Arquitectura](../explicacion/arquitectura.md)
- [Depuracion y troubleshooting](../como-hacer/depuracion-y-solucion-de-problemas.md)
