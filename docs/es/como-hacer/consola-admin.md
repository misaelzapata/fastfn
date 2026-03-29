# Consola y administración


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN resuelve dependencias y build por función según el runtime: Python usa `requirements.txt`, Node usa `package.json`, PHP instala desde `composer.json` cuando existe, y Rust compila handlers con `cargo`. En `fastfn dev --native` necesitas runtimes y herramientas del host; `fastfn dev` depende de un daemon de Docker activo.
## Ficha rapida

- Complejidad: Intermedia
- Tiempo tipico: 10-15 minutos
- Úsala cuando: necesitas endurecer /console y /_fn
- Resultado: la superficie admin queda expuesta solo como corresponde


Esta guia esta enfocada **solo** en la superficie administrativa:

- `/console`
- `/_fn/*`

Para auth de negocio de funciones (API key, sesion, JWT), usa:

- `docs/es/tutorial/auth-y-secretos.md`

## Alcance

Esta pagina cubre:

- habilitar/deshabilitar UI/API de consola
- proteccion de escritura
- modo local-only
- token admin para operaciones remotas
- deep links de consola por URL
- dashboard Gateway para rutas mapeadas

## Flags

- `FN_UI_ENABLED` (default `0`)
- `FN_CONSOLE_API_ENABLED` (default `1`)
- `FN_CONSOLE_WRITE_ENABLED` (default `0`)
- `FN_CONSOLE_LOCAL_ONLY` (default `1`)
- `FN_ADMIN_TOKEN` (opcional)
- `FN_CONSOLE_LOGIN_ENABLED` (default `0`, solo UI)
- `FN_CONSOLE_LOGIN_API` (default `0`, si se habilita: protege API de consola tambien)
- `FN_CONSOLE_LOGIN_USERNAME`
- `FN_CONSOLE_LOGIN_PASSWORD_HASH` o `FN_CONSOLE_LOGIN_PASSWORD_HASH_FILE` (preferido)
- `FN_CONSOLE_LOGIN_PASSWORD` o `FN_CONSOLE_LOGIN_PASSWORD_FILE` (fallback legacy/en texto plano)
- `FN_CONSOLE_SESSION_SECRET` o `FN_CONSOLE_SESSION_SECRET_FILE`
- `FN_CONSOLE_SESSION_TTL_S` (default `43200`)
- `FN_CONSOLE_LOGIN_RATE_LIMIT_MAX` (default `5`)
- `FN_CONSOLE_LOGIN_RATE_LIMIT_WINDOW_S` (default `300`)
- `FN_CONSOLE_RATE_LIMIT_MAX` (default `120`)
- `FN_CONSOLE_RATE_LIMIT_WINDOW_S` (default `60`)
- `FN_CONSOLE_WRITE_RATE_LIMIT_MAX` (default `30`)

## Baseline recomendado

- mantener `FN_UI_ENABLED=0` salvo necesidad
- mantener `FN_CONSOLE_LOCAL_ONLY=1`
- mantener `FN_CONSOLE_WRITE_ENABLED=0` por defecto
- definir `FN_ADMIN_TOKEN` para admin remota controlada
- preferir hash de password o secretos `*_FILE` antes que vars en texto plano
- definir un secreto de sesion explicito; no hay fallback implicito a `FN_ADMIN_TOKEN`

## Login opcional (UI de consola)

Si quieres una pantalla de login para `/console`:

```bash
export FN_CONSOLE_LOGIN_ENABLED=1
export FN_CONSOLE_LOGIN_USERNAME='admin'
export FN_CONSOLE_LOGIN_PASSWORD_HASH='pbkdf2-sha256:<iterations>:<salt_hex>:<digest_hex>'
export FN_CONSOLE_SESSION_SECRET='change-me-too'
```

Genera un hash PBKDF2 recomendado usando solo la libreria estandar de Python:

```bash
python3 - <<'PY'
import hashlib
import secrets

password = "change-me".encode()
iterations = 200000
salt_hex = secrets.token_hex(16)
digest_hex = hashlib.pbkdf2_hmac("sha256", password, bytes.fromhex(salt_hex), iterations).hex()
print(f"pbkdf2-sha256:{iterations}:{salt_hex}:{digest_hex}")
PY
```

Si usas secretos montados o archivos en contenedor:

```bash
export FN_CONSOLE_LOGIN_ENABLED=1
export FN_CONSOLE_LOGIN_USERNAME='admin'
export FN_CONSOLE_LOGIN_PASSWORD_HASH_FILE='/run/secrets/console_password_hash'
export FN_CONSOLE_SESSION_SECRET_FILE='/run/secrets/console_session_secret'
```

Notas:

- `pbkdf2-sha256:<iterations>:<salt_hex>:<digest_hex>` es el formato recomendado.
- `sha256:<hex>` sigue funcionando como formato legacy de compatibilidad para instalaciones existentes.
- `FN_CONSOLE_LOGIN_PASSWORD` sigue funcionando, pero queda como fallback de compatibilidad y es menos seguro para produccion.
- Las sesiones nuevas quedan atadas al usuario y a las credenciales actuales del login, asi que rotar el password invalida automaticamente las sesiones emitidas despues de este cambio.

Si también quieres que la API de consola (`/_fn/*`) requiera cookie de login:

```bash
export FN_CONSOLE_LOGIN_API=1
```

La consola tambien tiene rate limiting general:

- los intentos de login usan `FN_CONSOLE_LOGIN_RATE_LIMIT_MAX` dentro de `FN_CONSOLE_LOGIN_RATE_LIMIT_WINDOW_S`
- la UI y las lecturas usan `FN_CONSOLE_RATE_LIMIT_MAX`
- las escrituras y llamadas no-GET de la API usan `FN_CONSOLE_WRITE_RATE_LIMIT_MAX`

## Ver estado actual de UI/API

```bash
curl -sS 'http://127.0.0.1:8080/_fn/ui-state'
```

## Usar token admin

```bash
curl -sS 'http://127.0.0.1:8080/_fn/ui-state' \
  -H 'x-fn-admin-token: my-secret-token'
```

## Cambiar estado en caliente

```bash
curl -sS 'http://127.0.0.1:8080/_fn/ui-state' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"ui_enabled":true,"api_enabled":true,"write_enabled":false,"local_only":true}'
```

Comportamiento de `/_fn/ui-state`:

- `GET` es solo lectura.
- `PUT|POST|PATCH|DELETE` son escritura y requieren permiso de escritura.

## Errores administrativos tipicos

- `403 console ui local-only`
- `403 console api local-only`
- `403 console write disabled`
- `404 console ui disabled`

## Deep links de consola (URLs reales)

La consola soporta deep links que sobreviven refresh:

![Vista del dashboard de la consola de FastFN](../../assets/screenshots/admin-console-dashboard.png)

- `/console`
- `/console/explorer`
- `/console/explorer/<runtime>/<funcion>`
- `/console/explorer/<runtime>/<funcion>@<version>`
- `/console/gateway`
- `/console/configuration`
- `/console/crud`
- `/console/wizard`

Ejemplo:

- `/console/explorer/node/hello@v2`

Acceso rapido al dashboard Gateway:

- `/console/gateway`

La pestaña Gateway muestra:

- ruta publica mapeada
- funcion destino (`runtime/funcion@version`)
- metodos permitidos
- conflictos de rutas detectados en discovery

## Tour rapido de la UI

La consola esta organizada en tabs:

- **Explorer**: detalle de funcion + form de invocacion (`/_fn/invoke`).
- **Wizard**: paso a paso para crear funciones (ideal para principiantes).
- **Gateway**: dashboard de endpoints mapeados (URL publica -> funcion).
- **Configuration**: paneles agrupados para:
  - limites/metodos/rutas
  - config edge proxy (`edge.*`) para respuestas `{ "proxy": { ... } }`
  - schedule (cron por intervalo)
  - editor de env (secretos ocultos)
  - editor de codigo
- **CRUD**: crear/borrar funciones + toggles de acceso a consola.

Notas de schedule:

- El schedule se configura por funcion en `fn.config.json` bajo `schedule`.
- `GET /_fn/schedules` muestra estado (`next`, `last`, ultimo status/error).

## Checklist de hardening

- mantener consola/API en red privada o VPN
- no exponer `/_fn/*` a internet publica
- exigir token admin para operaciones de escritura
- habilitar escritura solo en ventanas de mantenimiento
- preferir `*_FILE` o password hasheado antes que secretos en texto plano
- ajustar el TTL de sesion segun tu riesgo operativo

## Objetivo

Alcance claro, resultado esperado y público al que aplica esta guía.

## Prerrequisitos

- CLI de FastFN disponible
- Dependencias por modo verificadas (Docker para `fastfn dev`, OpenResty+runtimes para `fastfn dev --native`)

## Checklist de Validación

- Los comandos de ejemplo devuelven estados esperados
- Las rutas aparecen en OpenAPI cuando aplica
- Las referencias del final son navegables

## Solución de Problemas

- Si un runtime cae, valida dependencias de host y endpoint de health
- Si faltan rutas, vuelve a ejecutar discovery y revisa layout de carpetas

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Depuracion y solucion de problemas](./depuracion-y-solucion-de-problemas.md)
- [Variables de entorno](../referencia/variables-de-entorno.md)
- [Checklist Ejecutar y Probar](ejecutar-y-probar.md)
