# Arquitectura


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
## Objetivos de diseño

La plataforma optimiza tres cosas al mismo tiempo:

1. desarrollo local rápido
2. control operativo por función
3. baja complejidad operativa

Por eso mantiene OpenResty como único edge HTTP y usa runtimes de lenguaje por Unix sockets.

## Modelo mental

Cliente HTTP -> OpenResty (rutas públicas como `/hello`) -> runtime (`python`/`node`/`php`/`rust`) -> handler

En Docker, todo corre dentro del servicio `openresty`, incluyendo procesos runtime.

## Descubrimiento por filesystem (configurable)

No existe `routes.json` estático. Las funciones se descubren desde un root de filesystem (tu "directorio de funciones").

Convención recomendada: crea un directorio `functions/` en la raíz del repo y apunta FastFN a ese lugar.

Formas comunes de configurar el directorio de funciones:

- `fastfn dev functions`
- `fastfn.json` -> `"functions-dir": "functions"`
- `FN_FUNCTIONS_ROOT=/ruta/absoluta/a/functions`

La lista de runtimes también es configurable:

- `FN_RUNTIMES` (CSV, ejemplo `python,node,php,rust`)

El mapeo de sockets es configurable:

- `FN_RUNTIME_SOCKETS` (JSON runtime -> socket URI)
- `FN_SOCKET_BASE_DIR` (base de sockets si no hay mapa)

Precedencia ante colisiones de rutas:

- Si el mismo nombre existe en varios runtimes, `/<name>` resuelve al primer runtime en `FN_RUNTIMES`.
- Si `FN_RUNTIMES` no está definido, usa orden alfabético de carpetas runtime.

## Politica por funcion

`fn.config.json` puede definir:

- `invoke.methods`
- `timeout_ms`
- `max_concurrency`
- `max_body_bytes`

Esto evita rigidez global y deja control cerca del dueño de la función.

## Contrato runtime uniforme

Todos los runtimes comparten el mismo protocolo:

- request: `{ fn, version, event }`
- response: `{ status, headers, body }`

Así el gateway se mantiene agnóstico al lenguaje.

## Seguridad

Controles incluidos:

- proteccion contra path traversal
- proteccion contra escapes por symlink en writes
- masking de secretos (`fn.env.json` con `is_secret=true`) en consola
- permisos de consola por flags (`ui/api/write/local_only`)
- sandbox estricto por funcion habilitado por default (`FN_STRICT_FS=1`)

## Tradeoffs conocidos

- latencia mayor que Lua embebido en algunos casos
- discovery filesystem requiere disciplina de estructura
- auth pública es por función (no centralizada por defecto)

Tradeoff intencional: velocidad local fuerte + control práctico.

## Modelo de rendimiento y escalado real

El throughput de FastFN depende de ambas capas:

- OpenResty/Nginx (edge de red, manejo de conexiones, parsing HTTP)
- capacidad del runtime (workers de Node/Python/PHP/Lua/Rust/Go y costo del handler)

Agregar más workers puede subir el throughput, pero solo hasta el siguiente cuello:

- saturación de CPU
- overhead de dependencias del runtime (comportamiento cold/warm, carga de paquetes)
- límites por función (`max_concurrency`, `worker_pool.max_workers`, `worker_pool.max_queue`)
- latencia de I/O externa (DB, APIs de terceros)

En resumen: más workers ayuda cuando el cuello está en el runtime, pero no salta límites del gateway, de red o de dependencias externas.

## Trabajo futuro y deuda técnica

La arquitectura actual es apta para producción, pero estas son líneas activas de optimización:

- autosizing adaptativo del worker pool por función según latencia/errores observados
- mejores defaults de backpressure (timeout de cola y estrategia de overflow por perfil de tráfico)
- menor overhead de IPC en hot paths (mejoras de framing/serialización)
- mayor paridad entre runtimes en features avanzadas del pool
- observabilidad más clara de tiempo en cola vs tiempo de ejecución
- estandarización de matriz de benchmarks (misma forma de carga entre runtimes, perfiles reproducibles)

No son bloqueantes para uso normal; son la siguiente capa para mejorar percentiles altos bajo tráfico en ráfaga.

## Problema

Qué dolor operativo o de DX resuelve este tema.

## Modelo Mental

Cómo razonar esta feature en entornos similares a producción.

## Decisiones de Diseño

- Por qué existe este comportamiento
- Qué tradeoffs se aceptan
- Cuándo conviene una alternativa

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
