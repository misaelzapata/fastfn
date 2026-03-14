# Benchmarks de rendimiento

> Estado verificado al **14 de marzo de 2026**.
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

## Cómo leer estos números

Este benchmark sirve porque muestra los matices reales, no una sola conclusión simplificada:

- sumar daemons ayudó mucho a Python en ambos modos
- sumar daemons ayudó un poco a Node en ambos modos
- PHP reaccionó distinto entre native y Docker
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
- Si PHP o Rust empeoran con más daemons, comprueba si el overhead extra de procesos es mayor que el costo del handler.
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
