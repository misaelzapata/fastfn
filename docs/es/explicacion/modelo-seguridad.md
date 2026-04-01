# Modelo de seguridad

> Estado verificado al **1 de abril de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.

La seguridad en FastFN es por capas. El gateway protege rutas y políticas, los runtimes aplican restricciones durante la ejecución de funciones y los image workloads sobre Firecracker agregan una política de acceso público separada más una red privada workload-to-workload.

## Alcance y supuestos

- El código de función es código del proyecto.
- La entrada del usuario no es confiable.
- El modo estricto de runtime está activo por defecto.
- No es aislamiento a nivel kernel.

## 1) Controles en el edge

Antes de llegar a un runtime o a un broker residente de app, el gateway aplica:

- validación de ruta y método
- allowlist de métodos por función (`invoke.methods`)
- allowlist de hosts por función (`invoke.allow_hosts`)
- límite de body (`max_body_bytes`)
- timeout y concurrencia por función
- mapeo consistente de errores (`404/405/413/429/502/503/504`)
- protección denylist para paths del control-plane como `/_fn/*` y `/console/*`

Para image workloads públicos, el mismo edge además aplica el firewall simple:

- `access.allow_hosts` en endpoints HTTP
- `access.allow_cidrs` en endpoints HTTP y TCP públicos
- matching acumulativo cuando en un endpoint HTTP existen listas de host y CIDR
- manejo de proxies confiables vía `FN_TRUSTED_PROXY_CIDRS`

## 2) Sandbox estricto de filesystem para funciones

Por defecto (`FN_STRICT_FS=1`) el modo estricto de runtime está activo.

Estado actual del enforcement:

- Python y Node usan intercepción estricta de filesystem para lecturas, escrituras y subprocess.
- PHP, Lua, Rust y Go aplican validación de paths y ejecución acotada dentro de su modelo de runtime.

Permitido por defecto:

- el directorio de la función
- directorios de dependencias del runtime dentro de la función (`.deps`, `node_modules`)
- rutas de sistema necesarias para runtimes (`/tmp`, certificados, timezone)

Bloqueado por defecto:

- lecturas arbitrarias fuera del sandbox de la función
- lectura de archivos protegidos de plataforma desde handlers:
  - `fn.config.json`
  - `fn.env.json`
- ejecución de subprocess desde handlers mientras el modo estricto esté activo

Extensión opcional:

- `FN_STRICT_FS_ALLOW=/ruta1,/ruta2` para permitir raíces extra de lectura/escritura

## 3) Manejo de secretos

El env de función se carga desde `fn.env.json` y se inyecta en `event.env` por invocación.

- Las vistas de UI y API enmascaran secretos declarados como `{"value":"...","is_secret":true}`.
- La consola no expone valores secretos en texto plano.
- El state público de workloads mantiene URLs redactadas cuando el protocolo lleva credenciales; las credenciales quedan en env vars y no embebidas en `*_URL`.

## 4) Controles de acceso de consola

La superficie de gestión (`/console`, `/_fn/*`) se controla con flags:

- `FN_UI_ENABLED`
- `FN_CONSOLE_API_ENABLED`
- `FN_CONSOLE_WRITE_ENABLED`
- `FN_CONSOLE_LOCAL_ONLY`
- `FN_ADMIN_TOKEN` (override por header `x-fn-admin-token`)

## 5) Fronteras de red

La comunicación gateway-runtime usa sockets Unix, sin listeners TCP públicos.

- Python: `unix:/tmp/fastfn/fn-python.sock`
- Node: `unix:/tmp/fastfn/fn-node.sock`
- PHP: `unix:/tmp/fastfn/fn-php.sock`
- Rust: `unix:/tmp/fastfn/fn-rust.sock`

Los image workloads sobre Firecracker agregan dos fronteras más:

- el tráfico público pasa por brokers estables del lado host
- el tráfico privado entre workloads pasa por aliases loopback en guest y bridges `vsock` mediados por el host

Diferencias importantes:

- la política de acceso público solo aplica a endpoints públicos de apps/services
- el tráfico privado `*.internal` no se filtra con `allow_hosts` ni `allow_cidrs`
- un `fn.config.json` local define scope y visibilidad hacia carpetas descendientes, pero no publica nada por sí solo

Ejemplo práctico de firewall:

```json
{
  "app": {
    "dockerfile": "./Dockerfile.fastfn",
    "context": ".",
    "port": 8000,
    "routes": ["/*"],
    "access": {
      "allow_hosts": ["app.example.com", "*.corp.example.com"],
      "allow_cidrs": ["203.0.113.0/24"]
    }
  }
}
```

Reglas:

- `allow_hosts` es solo para HTTP.
- `allow_cidrs` acepta CIDR e IP simple.
- Los puertos TCP públicos solo soportan `allow_cidrs`.
- Solo los proxies incluidos en `FN_TRUSTED_PROXY_CIDRS` pueden influir en la IP cliente vía forwarding headers.

## 6) Límites actuales

- El sandbox es a nivel runtime/lenguaje, no kernel.
- Para aislamiento multi-tenant fuerte, agrega controles host-level como contenedores, seccomp, cgroups o workers aislados.
- Los workloads Firecracker de esta branch requieren Linux/KVM.
- Los bind mounts del host no forman parte de la frontera de storage para Firecracker en esta branch.
- El firewall público de workloads es deliberadamente simple. Sirve para allowlists gruesas, no reemplaza un WAF ni un proxy con identidad.

## Ver también

- [Arquitectura](./arquitectura.md)
- [Especificación de funciones](../referencia/especificacion-funciones.md)
- [Configuración global](../referencia/config-fastfn.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
