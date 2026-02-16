# Modelo de seguridad

La seguridad en fastfn es por capas. El gateway protege rutas y políticas; los runtimes aplican restricciones durante ejecución.

## Alcance y supuestos

- El código de función es código del proyecto.
- La entrada del usuario no es confiable.
- El modo estricto de runtime está activo por defecto.
- No es aislamiento a nivel kernel.

## 1) Controles en el edge (OpenResty)

Antes de invocar runtime, el gateway aplica:

- validación de ruta y método
- allowlist de métodos por función (`invoke.methods`)
- límite de body (`max_body_bytes`)
- timeout y concurrencia por función
- mapeo consistente de errores (`404/405/413/429/502/503/504`)

## 2) Sandbox estricto de filesystem (runtime, default)

Por defecto (`FN_STRICT_FS=1`) el modo estricto de runtime está activo.

Estado de enforcement:

- Python/Node: intercepción estricta de filesystem (lectura/escritura/subprocess); PHP/Lua/Rust aplican validación de rutas y ejecución acotada en su modelo de runtime.

Permitido por defecto:

- directorio de la función
- directorios de dependencias del runtime dentro de la función (`.deps`, `node_modules`)
- rutas de sistema necesarias para runtime (`/tmp`, certs/timezone)

Bloqueado por defecto:

- lecturas arbitrarias fuera del sandbox de función
- lectura de archivos protegidos de plataforma desde handlers:
  - `fn.config.json`
  - `fn.env.json`
- ejecución de subprocess desde handlers (modo estricto)

Extensión opcional:

- `FN_STRICT_FS_ALLOW=/ruta1,/ruta2` para permitir raíces extra de forma explícita.

## 3) Manejo de secretos

El env de función se carga desde `fn.env.json` y se inyecta en `event.env` por invocación.

- UI/API enmascara secretos usando entradas en `fn.env.json` (`{"value":"...","is_secret":true}`).
- La consola no expone valores secretos en texto plano.

## 4) Controles de acceso de consola

La superficie de gestión (`/console`, `/_fn/*`) usa flags:

- `FN_UI_ENABLED`
- `FN_CONSOLE_API_ENABLED`
- `FN_CONSOLE_WRITE_ENABLED`
- `FN_CONSOLE_LOCAL_ONLY`
- `FN_ADMIN_TOKEN` (override por header `x-fn-admin-token`)

## 5) Frontera de red

La comunicación gateway-runtime usa sockets Unix, sin listeners TCP públicos.

- Python: `unix:/tmp/fastfn/fn-python.sock`
- Node: `unix:/tmp/fastfn/fn-node.sock`
- PHP: `unix:/tmp/fastfn/fn-php.sock`
- Rust: `unix:/tmp/fastfn/fn-rust.sock`

## 6) Límites actuales

- El sandbox es a nivel runtime/lenguaje, no kernel.
- Para aislamiento multi-tenant fuerte, agregar controles host-level (contenedores, seccomp, cgroups, workers aislados).
