# FastFN — Bugs y hallazgos (pruebas de ejemplos, 2026-03-28)

## Bugs reales (a corregir)

### 1. PACKS_DIR resuelve desde BASE_DIR en vez de FN_FUNCTIONS_ROOT

Los daemons Python y Node tenían la resolución de packs desacoplada del layout real del repo. El cierre correcto es soportar ambos layouts que ya usa FastFN:

- root compartido: `<FN_FUNCTIONS_ROOT>/.fastfn/packs/<runtime>/<pack>`
- root runtime-scoped: si `FN_FUNCTIONS_ROOT` termina en `python` o `node`, también revisar el root padre en `.fastfn/packs/<runtime>/<pack>`

- `srv/fn/runtimes/python-daemon.py` línea 45
- `srv/fn/runtimes/node-daemon.js` línea 29
- Copias embebidas en `cli/embed/runtime/srv/fn/runtimes/`

Criterio de cierre:

- `/pack-qr` (python), `/pack-qr-node` (node) y `/ts-hello` (node) funcionan con `fastfn dev examples/functions`
- también funcionan roots runtime-scoped como `fastfn dev examples/functions/python` y `fastfn dev examples/functions/node`

### 2. Go session-demo usa contrato incorrecto

`examples/functions/go/session-demo/main.go` usa `func main()` leyendo de stdin, pero go-daemon.py exige `func handler(event map[string]interface{}) interface{}` (líneas 212, 803). Discovery encuentra `main.go`, pero el runtime falla con 500.

### 3. Rust session-demo roto por discovery

`examples/functions/rust/session-demo/src/main.rs` no se descubre porque:
- Discovery solo reconoce `handler.rs` para Rust (scan.go:39)
- `src` está en `defaultZeroConfigIgnoreDirs` (scan.go:57)
- Además usa `fn main()` en vez de `pub fn handler(event: Value) -> Value`

## Docs y expectativas (a corregir)

### 4. rest-api-methods README engañoso

El README dice "pick one runtime" pero el comando `fastfn dev examples/functions/rest-api-methods` no selecciona ninguno. Con los 6 lenguajes presentes, todas las rutas devuelven 409 (ambiguity). El 409 es comportamiento correcto del router.

### 5. next-style y polyglot-tutorial no aclaran Rust/Go en native

`nativeDefaultRuntimes` es `["python", "node", "php", "lua"]` (runner.go:58). Los READMEs muestran curls a rutas Rust/Go sin mencionar que requieren `FN_RUNTIMES`.

## Limitaciones conocidas (documentar)

### 6. Scheduler ignora funciones zero-config file-based

`scheduler.lua` (línea 1229) solo itera `catalog.runtimes[runtime].functions`. Las funciones zero-config file-based solo se registran en `catalog.mapped_routes`, así que sus configs de `schedule` se ignoran silenciosamente. Los schedules requieren estructura runtime-scoped (`python/mi-funcion/`) o keys explícitas (`runtime`, `name`, `entrypoint`, `invoke.routes`) en fn.config.json.

### 7. PHP daemon 503 en polyglot-tutorial

`step-3/index.php` devuelve 503 intermitentemente al correr junto a otros runtimes. El código PHP es correcto y funciona en ejemplos standalone. Queda como fallo observado pendiente de repro consistente y logs del daemon para identificar la causa real.
