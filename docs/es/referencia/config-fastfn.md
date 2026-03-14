# Referencia de `fastfn.json`

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: FastFN resuelve dependencias y build por función según el runtime: Python usa `requirements.txt`, Node usa `package.json`, PHP instala desde `composer.json` cuando existe, y Rust compila handlers con `cargo`. En `fastfn dev --native` necesitas runtimes y herramientas del host, mientras que `fastfn dev` depende de un daemon de Docker activo.

`fastfn.json` es el archivo de configuración principal del CLI. FastFN lo lee desde el directorio actual, salvo que uses `--config`.

## Vista rápida

- Complejidad: Referencia
- Tiempo típico: 10-20 minutos
- Úsala cuando: quieres definir en un solo lugar el directorio de funciones, el comportamiento de rutas, la cantidad de daemons y los binarios del host
- Resultado: comportamiento reproducible en local y en CI sin comandos largos

## Claves soportadas

| Clave | Tipo | Qué controla |
| --- | --- | --- |
| `functions-dir` | `string` | Directorio de funciones por defecto cuando no pasas uno al CLI. |
| `public-base-url` | `string` | URL pública canónica para `servers[0].url` en OpenAPI. |
| `openapi-include-internal` | `boolean` | Si los endpoints internos `/_fn/*` aparecen en OpenAPI y Swagger. |
| `force-url` | `boolean` | Opt-in global que permite que una ruta declarada por config reemplace una URL ya mapeada. |
| `domains` | `array` | Dominios usados por `fastfn doctor domains`. |
| `runtime-daemons` | `object` o `string` | Cuántas instancias de daemon arrancar por runtime externo. |
| `runtime-binaries` | `object` o `string` | Qué ejecutable del host debe usar FastFN para cada runtime o herramienta. |

Notas:

- La forma recomendada es kebab-case.
- Los alias de compatibilidad siguen funcionando en proyectos anteriores.
- `domains` solo afecta a `fastfn doctor domains`; no bloquea hosts entrantes por sí sola.
- `runtime-daemons` aplica a runtimes externos (`node`, `python`, `php`, `rust`, `go`). `lua` corre dentro de OpenResty, así que un count para `lua` se ignora.

## Ejemplo 1: Directorio de funciones por defecto

`fastfn.json`

```json
{
  "functions-dir": "functions"
}
```

Ejecuta:

```bash
fastfn dev
```

Comportamiento esperado:

- FastFN usa `functions/` automáticamente.

## Ejemplo 2: Escalar daemons por runtime

`fastfn.json`

```json
{
  "functions-dir": "functions",
  "runtime-daemons": {
    "node": 3,
    "python": 3,
    "php": 2,
    "rust": 2
  }
}
```

Ejecuta:

```bash
FN_RUNTIMES=node,python,php,rust fastfn dev --native
```

Valida:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
```

Qué deberías ver:

- `node`, `python`, `php` y `rust` muestran un modo de `routing`.
- Cuando un runtime tiene más de un socket, `routing` pasa a `round_robin`.
- `sockets` lista cada instancia por separado.

También puedes usar la forma string:

```json
{
  "runtime-daemons": "node=3,python=3,php=2,rust=2"
}
```

## Ejemplo 3: Elegir binarios del host

`fastfn.json`

```json
{
  "runtime-binaries": {
    "python": "python3.12",
    "node": "node20",
    "php": "php8.3",
    "composer": "composer",
    "cargo": "cargo",
    "openresty": "/opt/homebrew/bin/openresty"
  }
}
```

Detalle importante:

- FastFN elige un ejecutable por clave.
- Todas las instancias de ese runtime usan el mismo ejecutable configurado.
- Tener varios daemons no implica mezclar versiones dentro del mismo grupo.

Claves soportadas para binarios:

| Clave | Override por env | Se usa para |
| --- | --- | --- |
| `openresty` | `FN_OPENRESTY_BIN` | OpenResty en modo native o en el entrypoint del contenedor. |
| `docker` | `FN_DOCKER_BIN` | CLI de Docker usada por `fastfn dev` y `fastfn doctor`. |
| `python` | `FN_PYTHON_BIN` | Daemon de Python y launchers escritos en Python para PHP, Rust y Go. |
| `node` | `FN_NODE_BIN` | Proceso del daemon de Node. |
| `npm` | `FN_NPM_BIN` | Instalación de dependencias Node. |
| `php` | `FN_PHP_BIN` | Ejecución del worker PHP dentro del daemon PHP. |
| `composer` | `FN_COMPOSER_BIN` | Instalación de dependencias PHP. |
| `cargo` | `FN_CARGO_BIN` | Builds de Rust. |
| `go` | `FN_GO_BIN` | Builds usados por el daemon de Go. |

Si solo necesitas un override temporal, las variables `FN_*_BIN` funcionan sin editar `fastfn.json`.

## Ejemplo 4: Mapa de sockets explícito (override avanzado)

`FN_RUNTIME_SOCKETS` puede reemplazar por completo los sockets generados.

Ejemplo:

```bash
export FN_RUNTIME_SOCKETS='{"node":["unix:/tmp/fastfn/node-1.sock","unix:/tmp/fastfn/node-2.sock"],"python":"unix:/tmp/fastfn/python.sock"}'
fastfn dev --native functions
```

Reglas:

- Un runtime puede usar un string o un array.
- Si defines `FN_RUNTIME_SOCKETS`, gana sobre `runtime-daemons` y `FN_RUNTIME_DAEMONS`.
- Conviene usarlo solo cuando necesitas controlar las rutas de socket de forma explícita.

## Ejemplo 5: URL pública y OpenAPI interna

`fastfn.json`

```json
{
  "functions-dir": "functions",
  "public-base-url": "https://api.midominio.com",
  "openapi-include-internal": true
}
```

Valida:

```bash
curl -sS http://127.0.0.1:8080/_fn/openapi.json | jq '{server: .servers[0].url, has_health: (.paths | has("/_fn/health"))}'
```

## Prioridad

Ubicación del archivo:

1. `--config <ruta>`
2. `./fastfn.json`
3. `./fastfn.toml`

Cableado de daemons y sockets:

1. `FN_RUNTIME_SOCKETS`
2. `FN_RUNTIME_DAEMONS`
3. `runtime-daemons`
4. Por defecto: un daemon por runtime externo

Selección de binarios:

1. Variable `FN_*_BIN` de esa clave
2. `runtime-binaries`
3. Candidatos por defecto de FastFN (`python3` y luego `python`, `node`, `php`, `cargo`, etc.)

Base URL de OpenAPI:

1. `FN_PUBLIC_BASE_URL`
2. `public-base-url`
3. `X-Forwarded-Proto` + `X-Forwarded-Host`
4. Scheme + `Host` del request

## Validación

Smoke test:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
curl -sS http://127.0.0.1:8080/_fn/openapi.json | jq '.servers[0].url'
```

## Troubleshooting

- Si native dice que falta un runtime, define la `FN_*_BIN` correspondiente o usa `runtime-binaries`.
- Si un runtime aparece con `up=false`, revisa primero la lista `sockets` en `/_fn/health`.
- Si `runtime-daemons` parece no tener efecto, confirma que estás escalando un runtime externo y no `lua`.
- Si los sockets no coinciden con el patrón generado, revisa si tienes `FN_RUNTIME_SOCKETS` en el entorno.

## Enlaces relacionados

- [Especificación de funciones](especificacion-funciones.md)
- [Referencia API HTTP](api-http.md)
- [Arquitectura](../explicacion/arquitectura.md)
- [Benchmarks de rendimiento](../explicacion/benchmarks-rendimiento.md)
- [Escalar daemons de runtime](../como-hacer/escalar-daemons-runtime.md)
- [Ejecutar y probar](../como-hacer/ejecutar-y-probar.md)
