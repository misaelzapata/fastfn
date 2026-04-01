# Referencia de `fastfn.json`

> Estado verificado al **1 de abril de 2026**.
> Nota de runtime: FastFN resuelve dependencias y build por función según el runtime: Python usa `requirements.txt`, Node usa `package.json`, PHP instala desde `composer.json` cuando existe, y Rust compila handlers con `cargo`. En `fastfn dev --native` necesitas runtimes y herramientas del host, mientras que `fastfn dev` depende de un daemon de Docker activo.

`fastfn.json` es el archivo de configuración principal del CLI. FastFN lo lee desde el directorio actual, salvo que uses `--config`.

## Vista rápida

- Complejidad: Referencia
- Tiempo típico: 10-20 minutos
- Úsala cuando: quieres definir en un solo lugar el directorio de funciones, el comportamiento de rutas, la cantidad de daemons y los binarios del host
- Nota sobre workloads con imágenes: `apps` y `services` en este branch viven en modo native (`fastfn dev --native`, `fastfn run --native`) y corren como microVMs Firecracker desde bundles locales, imágenes de registry, `image_file` o `dockerfile`
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
| `hot-reload` | `boolean` | Habilita/deshabilita hot reload para comandos `dev` y `run`. Default: `true`. |
| `apps` | `object` | Apps HTTP públicas respaldadas por microVMs Firecracker. |
| `services` | `object` | Workloads privados de soporte respaldados por microVMs Firecracker. |

Notas:

- La forma recomendada es kebab-case.
- Los alias de compatibilidad siguen funcionando en proyectos anteriores.
- `domains` solo afecta a `fastfn doctor domains`; no bloquea hosts entrantes por sí sola.
- `runtime-daemons` aplica a runtimes externos (`node`, `python`, `php`, `rust`, `go`). `lua` corre dentro de OpenResty, así que un count para `lua` se ignora.
- `apps` requieren al menos una entrada pública en `routes` y un `port` principal.
- `services` quedan privados por defecto y exponen variables de conexión hacia funciones y apps.
- Cada workload con imagen debe elegir exactamente una fuente: `image`, `image_file` o `dockerfile`.
- `image` puede ser un directorio bundle local de Firecracker o una referencia OCI/registry como `mysql:8.4`.
- `image_file` carga un archivo OCI o Docker local y luego lo convierte a un bundle Firecracker cacheado.
- `dockerfile` builda vía la API de Docker Engine y convierte el resultado a un bundle Firecracker cacheado bajo `.fastfn/firecracker/images/`.
- En este branch, los workloads con imágenes solo están disponibles en modo native y sobre hosts Linux/KVM.
- El fast path queda residente y prewarmed por default: una vez arriba, el tráfico público e interno pasa por brokers estables y no rebuilda ni reinicia Firecracker por request.
- Los `fn.config.json` locales también pueden declarar `app`, `service`, `apps` o `services` sin tocar el `fastfn.json` global.

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

## Ejemplo 6: app Firecracker residente y servicio MySQL

`fastfn.json`

```json
{
  "functions-dir": "functions",
  "apps": {
    "admin": {
      "dockerfile": "./functions/admin/Dockerfile",
      "context": "./functions/admin",
      "port": 3000,
      "routes": ["/admin/*"],
      "lifecycle": {
        "idle_action": "run",
        "prewarm": true
      },
      "env": {
        "NODE_ENV": "production"
      }
    }
  },
  "services": {
    "mysql": {
      "image": "mysql:8.4",
      "port": 3306,
      "volume": "mysql-data",
      "lifecycle": {
        "idle_action": "run",
        "prewarm": true
      },
      "env": {
        "MYSQL_DATABASE": "app",
        "MYSQL_USER": "app",
        "MYSQL_PASSWORD": "secret",
        "MYSQL_ROOT_PASSWORD": "rootsecret"
      }
    }
  }
}
```

Ejecuta:

```bash
fastfn dev --native
```

Qué esperar:

- Requests que matchean `/admin/*` se proxyean al workload `admin` sobre Firecracker.
- Las funciones reciben `SERVICE_MYSQL_HOST`, `SERVICE_MYSQL_PORT` y `SERVICE_MYSQL_URL`.
- Los services también reciben aliases directos basados en su nombre real, como `MYSQL_HOST` o `MARIADB_HOST` cuando no hay ambigüedad.
- `/_fn/health` incluye snapshots de `apps` y `services` junto con la salud de runtimes, además de `broker_host`, `broker_port`, `internal_host`, `lifecycle_state` y `firecracker_pid`.

## Ejemplo 7: Restringir una app pública con `allow_hosts` y `allow_cidrs`

`fastfn.json`

```json
{
  "functions-dir": "functions",
  "apps": {
    "dashboard": {
      "image": "traefik/whoami:v1.10.2",
      "port": 80,
      "routes": ["/dashboard/*"],
      "access": {
        "allow_hosts": ["dashboard.example.com", "*.corp.example.com"],
        "allow_cidrs": ["203.0.113.0/24", "2001:db8::/32"]
      }
    }
  }
}
```

Qué esperar:

- El match de host es case-insensitive y soporta valores exactos además de wildcards tipo `*.example.com`.
- El match por IP acepta CIDR e IP simple; FastFN normaliza IP simple a `/32` o `/128`.
- Cuando en HTTP defines `allow_hosts` y `allow_cidrs`, ambos deben matchear.
- Los puertos TCP públicos solo soportan `allow_cidrs`.
- Si FastFN corre detrás de un proxy confiable, configura `FN_TRUSTED_PROXY_CIDRS` para que el gateway pueda usar `X-Forwarded-For` de forma segura.

Variante por carpeta:

```json
{
  "service": {
    "image": "postgres:16",
    "port": 5432,
    "volume": "payments-db"
  }
}
```

Si lo colocas en `functions/payments/fn.config.json`, declaras un service scoped a esa carpeta sin cambiar el `fastfn.json` root.

## Fuentes de workloads con imagen y lifecycle

Campos de fuente:

- `image`: directorio bundle local de Firecracker o referencia OCI/registry.
- `image_file`: archivo OCI o Docker local.
- `dockerfile`: path local al Dockerfile. Usa `context` cuando el build context no coincide con el directorio del Dockerfile.

Campos de lifecycle:

```json
{
  "lifecycle": {
    "idle_action": "run",
    "pause_after_ms": 15000,
    "prewarm": true
  }
}
```

Comportamiento:

- La política por default prioriza velocidad: `idle_action` default a `run` y `prewarm` default a `true` tanto para `apps` como para `services`.
- `pause_after_ms` solo importa cuando `idle_action` vale `pause`.
- Normalmente los `services` deberían quedar residentes; `pause` sirve más para apps de baja prioridad donde importa más ahorrar memoria que la latencia.
- Una vez prewarmed, FastFN atiende tráfico HTTP público y privado `*.internal` a través de brokers estables, así que los requests hot no rebuildan, no repullen y no reinician Firecracker.
- Los services prewarmed también esperan una pequeña ventana de estabilidad antes de marcarse como attachable. Eso evita que una app dependiente se conecte a un listener transitorio de bootstrap y falle durante el warmup.

## Política de acceso

El firewall simple vive sobre workloads públicos con imagen.

Formas soportadas:

- `app.access` y `service.access` funcionan como shorthand sobre el puerto público primario del schema simple `port + routes`.
- `ports[].access` aplica la política por endpoint público cuando usas el schema expandido `ports`.

Campos:

```json
{
  "access": {
    "allow_hosts": ["api.example.com", "*.corp.example.com"],
    "allow_cidrs": ["203.0.113.0/24", "2001:db8::/32"]
  }
}
```

Reglas:

- `allow_hosts` es solo para HTTP y matchea contra el host normalizado desde `Host` o `X-Forwarded-Host`.
- `allow_cidrs` funciona tanto para HTTP como para puertos TCP públicos.
- En HTTP, `allow_hosts` y `allow_cidrs` son acumulativos si ambos existen.
- En puertos TCP públicos, definir `allow_hosts` es error de config.
- Si `access` está vacío, el endpoint queda público sin restricción extra.

Health y state:

- `/_fn/health` mantiene los campos legacy `host`, `port` y `routes` para el endpoint HTTP primario de la app.
- La lista rica `public_endpoints` ahora incluye `protocol`, `routes`, `listen_port`, `allow_hosts` y `allow_cidrs`.
- El estado hot residente también expone `broker_host`, `broker_port`, `internal_host`, `internal_url`, `lifecycle_state` y `firecracker_pid`.

## Layout del bundle Firecracker

Cuando `image` apunta a un directorio local, FastFN espera este layout:

```text
images/
  admin/
    vmlinux
    rootfs.ext4
    fastfn-image.json   # opcional
  mysql/
    vmlinux
    rootfs.ext4
    fastfn-image.json   # opcional
```

Requisitos mínimos:

- `vmlinux`: kernel del guest.
- `rootfs.ext4`: filesystem raíz del guest.
- El software dentro del guest debe arrancar un proceso persistente escuchando en el puerto configurado.

Claves opcionales de `fastfn-image.json`:

```json
{
  "kernel": "vmlinux",
  "rootfs": "rootfs.ext4",
  "kernel_args": "console=ttyS0 reboot=k panic=1 pci=off",
  "guest_port": 10700,
  "vcpu_count": 1,
  "memory_mib": 512,
  "config_drive_bytes": 65536
}
```

Notas:

- Las rutas dentro de `fastfn-image.json` son relativas al directorio bundle.
- Si omites el manifiesto, FastFN usa `vmlinux`, `rootfs.ext4`, guest port `10700`, `1` vCPU y `512 MiB`.
- Los bundles locales son solo una de las fuentes posibles; FastFN también puede hacer pull/build de entradas OCI y cachear el bundle convertido automáticamente.

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
- Si no sabes si un setting va en config o en el entorno, revisa primero la referencia de variables de entorno.
- Si un app o service dice que no encontró un bundle local, confirma que `image` apunta a un directorio local con `vmlinux` y `rootfs.ext4`.
- Si un workload usa `image`, `image_file` o `dockerfile` y falla antes del boot, confirma que el daemon de Docker esté accesible porque hoy FastFN resuelve entradas OCI vía la API de Docker Engine.
- Si los requests hot se sienten más lentos de lo esperado, revisa `/_fn/health` y confirma que `broker_host`, `broker_port`, `lifecycle_state` y `firecracker_pid` permanezcan estables entre requests.
- Si los workloads con imágenes fallan enseguida en macOS o Windows, es esperado en este branch: Firecracker requiere un host Linux/KVM.
- Si `allow_cidrs` parece evaluar la IP del proxy en vez de la IP del cliente, configura `FN_TRUSTED_PROXY_CIDRS` con la lista de proxies confiables.

### Variables de entorno adicionales

| Variable | Default | Que controla |
|----------|---------|--------------|
| `FN_STRICT_FS` | `1` | Habilita sandboxing de filesystem para handlers. Usa `0` en desarrollo. |
| `FN_MAX_FRAME_BYTES` | — | Tamano maximo del frame de request aceptado por el socket del runtime. |
| `GO_BUILD_TIMEOUT_S` | `180` | Timeout en segundos para compilacion de handlers Go. |
| `FN_HOT_RELOAD` | `1` | Habilita hot reload. Aplica tanto a `dev` como a `run`. |

## Enlaces relacionados

- [Especificación de funciones](especificacion-funciones.md)
- [Variables de entorno](variables-de-entorno.md)
- [Referencia completa de config](fn-config-completo.md)
- [Referencia API HTTP](api-http.md)
- [Arquitectura](../explicacion/arquitectura.md)
- [Benchmarks de rendimiento](../explicacion/benchmarks-rendimiento.md)
- [Escalar daemons de runtime](../como-hacer/escalar-daemons-runtime.md)
- [Ejecutar y probar](../como-hacer/ejecutar-y-probar.md)
