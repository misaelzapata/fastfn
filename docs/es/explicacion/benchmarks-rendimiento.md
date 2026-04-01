# Benchmarks de rendimiento

> Estado verificado al **1 de abril de 2026**.
> Nota de runtime: FastFN resuelve dependencias y build por función según el runtime: Python usa `requirements.txt`, Node usa `package.json`, PHP instala desde `composer.json` cuando existe, y Rust compila handlers con `cargo`. En `fastfn dev --native` necesitas runtimes y herramientas del host, mientras que `fastfn dev` depende de un daemon de Docker activo.

Esta página publica snapshots reproducibles de rendimiento para FastFN. La idea es mostrar mediciones reales, no promesas generales.

## Vista rápida

- Complejidad: Intermedia
- Tiempo típico: 10-25 minutos
- Úsala cuando: necesitas una base antes de cambiar counts de daemons, colas o defaults de despliegue
- Resultado: números reproducibles y artefactos crudos para comparar en el tiempo

## Reglas del reporte

Cada benchmark debería incluir:

- forma de la carga
- modo runtime (`docker` o `native`)
- concurrencia y repeticiones
- mezcla de estados
- ruta del artefacto crudo

## Matriz Firecracker de image workloads

Snapshot: **1 de abril de 2026**.

Harness:

- Tool: `cd cli && go run ./tools/image-matrix-bench`
- Casos: `20`
- Loop hot: `50` requests secuenciales despues del prewarm
- Host: Linux/KVM con workloads Firecracker residentes
- Outputs: Markdown, JSON, CSV y logs por caso bajo `--smoke-dir` y el workspace del benchmark

Significado de las metricas:

- `build_or_pull_ms`: tiempo invertido en buildar un Dockerfile o hacer pull/load de la imagen
- `bundle_ms`: tiempo para convertir la entrada OCI al bundle Firecracker cacheado
- `prewarm_ready_ms`: tiempo hasta que el workload queda warm y attachable
- `first_ok_ms`: tiempo hasta la primera respuesta de verificacion exitosa
- `hot_p50_ms`, `hot_p95_ms`, `hot_p99_ms`: latencia steady-state despues del prewarm
- `same_firecracker_pid`: si el loop hot reutilizo el mismo proceso Firecracker antes y despues de medir

Resultados representativos:

| Caso | Fuente | Build/Pull | First OK | Hot p50 | Hot p95 | Hot p99 | Mismo PID |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| Flask (`flask-compose`) | Repo con Dockerfile | `1168ms` | `5017ms` | `1.94ms` | `3.05ms` | `4.10ms` | `true` |
| App desde registry (`traefik/whoami:v1.10.2`) | Imagen de registry | `98ms` | `2508ms` | `1.26ms` | `2.09ms` | `2.28ms` | `true` |
| FastAPI + Postgres (`fastapi-realworld`) | Repo Dockerfile + service privado | `1202ms` | `17036ms` | `5.29ms` | `7.02ms` | `7.94ms` | `true` |
| Dos servicios `postgres:16` iguales | Mismo OCI, mismo `5432` nativo | `1246ms` | `22090ms` | `10.92ms` | `28.85ms` | `32.58ms` | `true` |
| Rust + Postgres (`rust-postgres`) | Repo Dockerfile + service privado | `35139ms` | `47602ms` | `2.66ms` | `3.86ms` | `10.27ms` | `true` |

Qué muestra esta matriz:

- el build/pull en frio y el prewarm siguen estando en segundos
- despues del prewarm, el hot path residente baja a pocos milisegundos para apps ligeras y se mantiene en el mismo orden para apps con base de datos
- `same_firecracker_pid = true` en toda la matriz confirma que el loop hot reutilizo la misma microVM residente y no reinicio Firecracker
- servicios con OCI identico pueden coexistir en el mismo puerto nativo si sus nombres de workload son distintos

La matriz completa de 20 casos la produce el propio harness y la escribe en el smoke directory configurado como Markdown/JSON/CSV. La doc del repo deja aquí el resumen y el bundle operativo detallado se genera fuera del repo.

## Snapshot fast-path

Snapshot: **17 de febrero de 2026**.

Carga:

- Endpoints:
  - `GET /step-1` (Node)
  - `GET /step-2` (Python)
  - `GET /step-3` (PHP)
  - `GET /step-4` (Rust)
- Runner: `tests/stress/benchmark-fastpath.py`
- Requests por punto: `4000`
- Matriz de concurrencia: `1,2,4,8,16,20,24,32`

Mejor punto limpio (solo `200`):

| Runtime | Endpoint | Mejor punto limpio |
| --- | --- | ---: |
| Node | `/step-1` | `1772.69 RPS` (`c=16`) |
| Python | `/step-2` | `878.73 RPS` (`c=16`) |
| PHP | `/step-3` | `562.90 RPS` (`c=20`) |
| Rust | `/step-4` | `866.69 RPS` (`c=20`) |

Artefacto crudo:

- `tests/stress/results/2026-02-17-fastpath-default.json`

## Snapshot de routing multi-daemon

Snapshot: **14 de marzo de 2026**.

Carga:

- Fixture: `tests/fixtures/worker-pool`
- Patrón de requests: `6` requests concurrentes, `3` repeticiones medidas, `2` warmup requests por caso
- Costo del handler: `sleep(200ms)`
- Modos comparados:
  - `native`
  - `docker`
- Configuración comparada:
  - `runtime-daemons = 1`
  - `runtime-daemons = 3`

Resultados:

| Runtime | Path | Native `1` | Native `3` | Docker `1` | Docker `3` | Qué significa |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Node | `/slow-node` | `276.7ms` | `243.1ms` | `284.1ms` | `258.9ms` | mejora moderada en ambos modos |
| Python | `/slow-python` | `1283.3ms` | `451.6ms` | `1928.0ms` | `450.1ms` | mejora fuerte en ambos modos |
| PHP | `/slow-php` | `872.9ms` | `953.0ms` | `368.0ms` | `268.6ms` | peor en native, mejor en Docker |
| Rust | `/slow-rust` | `529.2ms` | `423.3ms` | `329.5ms` | `314.7ms` | mejora en ambos modos, pero pequeña en Docker |

Artefacto crudo:

- `tests/stress/results/2026-03-14-runtime-daemon-scaling-native.json`
- `tests/stress/results/2026-03-14-runtime-daemon-scaling-docker.json`

Comprobación adicional después de quitar el spawn de procesos PHP por request:

- chequeo rápido en PHP native: `1 daemon = 802.2ms`, `3 daemons = 625.9ms`
- mejora: `22.0%`
- artefacto: `tests/stress/results/2026-03-14-php-persistent-check.json`
- significado práctico: la regresión anterior de PHP en native ya no representa el path actual del runtime

## Cómo leer estos números

Este benchmark sirve porque muestra los matices reales, no una sola conclusión simplificada:

- sumar daemons ayudó mucho a Python en ambos modos
- sumar daemons ayudó un poco a Node en ambos modos
- PHP al principio reaccionó distinto entre native y Docker, pero la corrida posterior mejoró después de quitar el spawn por request dentro del daemon PHP
- Rust mejoró en ambos modos, pero la ganancia en Docker fue pequeña y conviene tratarla como dependiente de la carga

La conclusión práctica es simple:

- no conviene activar `runtime-daemons > 1` para todos los runtimes por defecto
- conviene medir la carga real que te importa
- `worker_pool` y `runtime-daemons` son controles distintos

También importa este punto operativo:

- FastFN expone salud por socket en `/_fn/health`
- un runtime puede seguir en `up=true` aunque uno de sus sockets esté en `up=false`
- los sockets sanos siguen atendiendo tráfico mientras se reinicia el daemon fallado

Ese comportamiento está cubierto por:

- `tests/integration/test-runtime-daemon-failover.sh`

`worker_pool.max_workers` es un control por función para admisión y cola. `runtime-daemons` es un control por runtime para ruteo entre sockets. Pueden combinarse, pero no resuelven el mismo problema.

## Cómo reproducir el benchmark de runtime-daemons

1. Arranca desde una pila limpia.
2. Corre el benchmark en `native`, `docker` o ambos.
3. Mantén la misma concurrencia, warmup y cantidad de requests.
4. Guarda el resultado crudo en `tests/stress/results/`.

Ejemplo mínimo:

```bash
python3 tests/stress/benchmark-runtime-daemons.py --mode both
```

Chequeo de validación:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
```

## Notas

- Los resultados dependen de CPU, carga de fondo y estado de instalación o build.
- El modo native y el modo Docker pueden dar resultados distintos, así que conviene publicar ambos si te importan ambos.
- Un mejor promedio solo sirve si la tasa de error sigue siendo aceptable.
- Python en Docker con `1` daemon fue el caso más variable de este snapshot, así que conviene mirar también las muestras crudas y no solo el promedio.

## Troubleshooting

- Si un runtime sale mucho más lento de lo esperado, mira primero `/_fn/health` y confirma que todos los sockets estén en `up=true`.
- Si las corridas varían demasiado, aumenta warmup y repeticiones.
- Si Rust empeora con más daemons, comprueba si el overhead extra de procesos es mayor que el costo del handler.
- Si PHP vuelve a empeorar, revisa primero que el runtime siga usando workers PHP persistentes y no haya caído en una ruta one-shot.
- Si Node o Python no mejoran, confirma en `/_fn/health` que el count extra de daemons realmente esté activo.

## Siguiente paso

Continúa con [Escalar daemons de runtime](../como-hacer/escalar-daemons-runtime.md) si quieres ajustar counts, o con [Ejecutar y probar](../como-hacer/ejecutar-y-probar.md) si quieres convertir estas mediciones en un flujo repetible de validación.

## Enlaces relacionados

- [Arquitectura](./arquitectura.md)
- [Especificación de funciones](../referencia/especificacion-funciones.md)
- [Configuración global](../referencia/config-fastfn.md)
- [Escalar daemons de runtime](../como-hacer/escalar-daemons-runtime.md)
- [Ejecutar y probar](../como-hacer/ejecutar-y-probar.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Plomería runtime/plataforma](../como-hacer/plomeria-runtime-plataforma.md)
