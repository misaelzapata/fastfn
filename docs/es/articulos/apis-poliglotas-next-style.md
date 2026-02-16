# APIs poliglotas con routing estilo Next en FastFN

FastFN ahora permite un flujo poliglota real: un gateway, un modelo de rutas, multiples runtimes dentro del mismo arbol de app.

Este articulo resume que significa eso en proyectos reales y por que baja friccion operativa.

## 1) Un modelo de URL para todos los lenguajes

Con routing estilo Next (tecnico: file-based dynamic-segment routing), las rutas salen del nombre del archivo, no de adaptadores por runtime.

Ejemplo en `examples/functions/next-style`:

- `users/index.js` -> `GET /users` (Node)
- `users/[id].js` -> `GET /users/:id` (Node)
- `blog/[...slug].py` -> `GET /blog/:slug*` (Python)
- `php/get.profile.[id].php` -> `GET /php/profile/:id` (PHP)
- `rust/get.health.rs` -> `GET /rust/health` (Rust)
- `admin/post.users.[id].py` -> `POST /admin/users/:id` (Python)

Lo clave es la paridad: las reglas de ruteo no cambian aunque cambie el runtime.

## 2) Elegir runtime pasa a ser una decision por archivo

En servicios poliglotas, muchos equipos migran endpoint por endpoint:

- Mantienen rutas estables.
- Reescriben un handler en otro lenguaje.
- Conservan OpenAPI y comportamiento de policy en gateway.

Como el runtime se infiere por extension (`.js`, `.py`, `.php`, `.rs`), esa migracion es incremental y de bajo riesgo.

## 3) Las sobreescrituras explicitas siguen disponibles

No quedas obligado a usar solo file routing:

1. `fn.config.json` (prioridad mas alta)
2. `fn.routes.json`
3. rutas por archivos

Esto habilita estrategia mixta:

- Casi todo zero-config.
- Algunas rutas mapeadas en `fn.routes.json`.
- Ajustes de policy/runtime en `fn.config.json`.

En `tests/fixtures/polyglot-demo`, este patron mezcla handlers Node/Python/PHP/Rust con mapeo explicito de rutas.

## 4) OpenAPI unificado para runtimes mixtos

Un problema tipico poliglota es tener documentacion separada por stack.

FastFN genera un solo OpenAPI desde el gateway usando las rutas descubiertas, asi los consumidores ven una API unica aunque los handlers esten en runtimes distintos.

Operativamente ayuda a:

- Generar SDK desde una sola spec.
- Revisar contratos de forma centralizada.
- Reducir desalineaciones entre equipos.

## 5) Mejor experiencia local en monorepos

`fastfn dev <root>` monta el root completo en desarrollo, entonces agregar archivos/carpetas nuevas se refleja sin remounts manuales.

En repos poliglotas esto evita el problema clasico donde un runtime recarga solo y otro requiere scripts extra.

## 6) Visibilidad warm/cold entre runtimes

Las respuestas exponen headers de estado:

- `X-FastFN-Function-State: cold|warm`
- `X-FastFN-Warmed: true`
- `X-FastFN-Warming: true` con `Retry-After: 1`

Esto importa mas en escenarios poliglotas, donde el startup difiere por runtime (por ejemplo primer build de Rust vs runtimes interpretados).

## 7) Ruta de adopcion recomendada

Secuencia sugerida:

1. Empezar con rutas por archivo en un folder.
2. Agregar endpoints de otros runtimes en el mismo arbol.
3. Introducir `fn.routes.json` solo donde se necesite control explicito.
4. Reservar `fn.config.json` para policy/concurrency/timeouts, no para cada ruta.
5. Validar con integration suite antes de rollout.

Resultado: un contrato de plataforma unico, flexibilidad de lenguaje y menor overhead operativo que mantener gateways separados por runtime.
