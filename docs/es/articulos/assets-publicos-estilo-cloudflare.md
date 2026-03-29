# Assets públicos estilo Cloudflare en FastFN

FastFN ahora puede servir una carpeta estática root-level directamente desde el gateway, con el mismo modelo mental que mucha gente espera de los static assets de Cloudflare Workers:

- una carpeta pública configurable
- montada en `/`
- fallback SPA opcional
- precedencia worker-first opcional

No es paridad 1:1 con Cloudflare. Es el subset más chico que sigue siendo fácil de explicar, fácil de testear y fácil de ejecutar en todos los runtimes de FastFN.

## La config

Pon esto en el `fn.config.json` raíz de tu app:

```json
{
  "assets": {
    "directory": "public",
    "not_found_handling": "single-page-application",
    "run_worker_first": false
  }
}
```

Significado:

- `directory`: carpeta pública relativa al root de la app. `public/` y `dist/` son comunes, pero el nombre es configurable.
- `not_found_handling`: `404` o `single-page-application`.
- `run_worker_first`: si es `true`, primero ganan las rutas de funciones y luego caen los assets como fallback.

## Los tres modos

### 1. Static-first

Úsalo cuando la app es mayormente estática y los handlers solo cubren algunos endpoints API.

- los archivos existentes en `public/` ganan primero
- las rutas de funciones se prueban solo si no hubo asset match
- ideal para landings con una superficie chica de `/api-*`

Demo ejecutable:

- `examples/functions/assets-static-first`

### 2. SPA fallback

Úsalo cuando el router del navegador controla deep links como `/dashboard/team`.

- `/dashboard/team` vuelve a `public/index.html`
- requests tipo archivo inexistente, como `/missing.js`, siguen devolviendo `404`
- una carpeta vacía no inventa rutas por sí sola

Demo ejecutable:

- `examples/functions/assets-spa-fallback`

### 3. Worker-first

Úsalo cuando los handlers son dueños del espacio de URLs y los assets solo son un shell de respaldo.

- FastFN prueba primero las rutas mapeadas
- los assets responden solo si ninguna ruta de función hizo match
- útil cuando `/hello` debe seguir siendo un handler aunque exista un archivo estático cercano

Demo ejecutable:

- `examples/functions/assets-worker-first`

## Casos límite importantes

- La carpeta de assets queda fuera del discovery zero-config, así que los archivos bajo `public/` no se publican accidentalmente como funciones.
- Solo se monta la carpeta configurada como assets. Las carpetas vecinas de funciones, los dotfiles y los intentos de traversal no quedan expuestos como archivos públicos.
- `/_fn/*` y `/console/*` siguen reservados.
- `GET` y `HEAD` se sirven directo desde el gateway.
- `/` y las URLs de directorio resuelven a `index.html`.
- Si la app solo tiene una carpeta de assets vacía, sin asset real, sin override de home y sin rutas de funciones, `/` devuelve `404` en vez de inventar una ruta pública nueva.

## Flujo de desarrollo

`fastfn dev` monta el root completo del proyecto para apps no-leaf, así que pueden aparecer carpetas y rutas nuevas sin reiniciar la stack.

Eso importa en proyectos con assets públicos porque:

- los archivos nuevos de assets quedan visibles enseguida
- las carpetas de funciones explícitas nuevas conservan su identidad real de función
- `handler.*` no degrada una función explícita a un alias falso de file route

## Dónde leer el contrato

- Guía: [`Zero-Config Routing`](../como-hacer/zero-config-routing.md)
- Referencia: [`Especificación de funciones`](../referencia/especificacion-funciones.md)
- Explicación: [`Arquitectura`](../explicacion/arquitectura.md)
