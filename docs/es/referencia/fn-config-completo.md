# Referencia completa de config

> Estado verificado al **27 de marzo de 2026**.

Esta pagina es una referencia practica de las claves de config que aparecen en la documentacion y ejemplos de FastFN.

## Vista rapida

- Complejidad: Referencia
- Tiempo tipico: 10-20 minutos
- Úsala cuando: quieres un solo lugar para revisar config global y config por funcion
- Resultado: sabes si un setting va en `fastfn.json`, `fn.config.json` o en una variable de entorno

## Config global: `fastfn.json`

| Clave | Tipo | Que controla |
| --- | --- | --- |
| `functions-dir` | `string` | Raiz por defecto de funciones |
| `public-base-url` | `string` | URL canonica del server de OpenAPI |
| `openapi-include-internal` | `boolean` | Si los endpoints internos aparecen en OpenAPI |
| `force-url` | `boolean` | Comportamiento global de override de rutas |
| `domains` | `array` | Entrada para checks de doctor domains |
| `runtime-daemons` | `object` o `string` | Counts de daemons por runtime |
| `runtime-binaries` | `object` o `string` | Ejecutables del host a usar |
| `hot-reload` | `boolean` | Habilita o deshabilita hot reload |

## Config por funcion: `fn.config.json`

| Clave | Tipo | Que controla |
| --- | --- | --- |
| `runtime` | `string` | Runtime explicito para una raiz de funcion |
| `name` | `string` | Nombre de funcion mostrado en discovery y rutas |
| `entrypoint` | `string` | Archivo handler explicito |
| `assets` | `object` | Comportamiento de assets estaticos en la raiz |
| `home` | `object` | Comportamiento de home para carpetas |
| `invoke` | `object` | Metodos, metadata y policy de invocacion |
| `schedule` | `object` | Scheduling por cron o intervalo |
| `worker_pool` | `object` | Colas y concurrencia por funcion |
| `edge` | `object` | Reglas de forwarding por edge proxy |
| `strict_fs` | `boolean` | Toggle de sandbox de filesystem por funcion |
| `zero_config` | `object` | Knobs de zero-config discovery, como ignore dirs |
| `zero_config_ignore_dirs` | `array` o `string` | Alias de compatibilidad para dirs ignorados extra |

## Bloques anidados utiles

### `assets`

Campos comunes:

- `directory`
- `not_found_handling`
- `run_worker_first`

Ejemplo:

```json
{
  "assets": {
    "directory": "public",
    "not_found_handling": "single-page-application",
    "run_worker_first": false
  }
}
```

### `invoke`

Campos comunes:

- `methods`
- `summary`
- `query`
- `body`
- `force_url`

Ejemplo:

```json
{
  "invoke": {
    "methods": ["GET", "POST"],
    "summary": "Ejemplo de handler"
  }
}
```

### `worker_pool`

Campos comunes:

- `enabled`
- `max_workers`
- `min_warm`
- `idle_ttl_seconds`

### `edge`

Se usa para respuestas que hacen proxy o forward hacia upstream en vez de devolver un payload normal de funcion.

## Prioridad practica

1. flags del CLI y argumentos explicitos
2. variables de entorno
3. `fastfn.json`
4. `fn.config.json`
5. defaults del runtime

Si no sabes donde va un setting, revisa primero los ejemplos y despues la referencia de variables de entorno.

## Enlaces relacionados

- [Referencia de fastfn.json](./config-fastfn.md)
- [Variables de entorno](./variables-de-entorno.md)
- [Arquitectura](../explicacion/arquitectura.md)
- [Ejecutar y probar](../como-hacer/ejecutar-y-probar.md)
