# Benchmarks de rendimiento

> Estado verificado al **13 de marzo de 2026**.
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

Snapshot: **13 de marzo de 2026**.

Carga:

- Modo: `native`
- Fixture: `tests/fixtures/worker-pool`
- Patrón de requests: `6` requests concurrentes, `3` repeticiones medidas, `2` warmup requests por caso
- Costo del handler: `sleep(200ms)`
- Configuración comparada:
  - `runtime-daemons = 1`
  - `runtime-daemons = 3`

Resultados:

| Runtime | Path | promedio con `1` daemon | promedio con `3` daemons | Efecto en esta prueba |
| --- | --- | ---: | ---: | --- |
| Node | `/slow-node` | `267.2ms` | `232.4ms` | `13.0%` más rápido |
| Python | `/slow-python` | `1281.9ms` | `447.4ms` | `65.1%` más rápido |
| PHP | `/slow-php` | `629.4ms` | `862.5ms` | `37.0%` más lento |
| Rust | `/slow-rust` | `384.6ms` | `417.7ms` | `8.6%` más lento |

Artefacto crudo:

- `tests/stress/results/2026-03-13-runtime-daemon-scaling-native.json`

## Cómo leer estos números

Este benchmark es útil porque muestra los dos lados:

- sumar daemons ayudó mucho a Python en esta prueba
- sumar daemons ayudó un poco a Node
- sumar daemons empeoró PHP y Rust en esta prueba

La conclusión práctica es simple:

- no conviene activar `runtime-daemons > 1` para todos los runtimes por defecto
- conviene medir la carga real que te importa
- `worker_pool` y `runtime-daemons` son controles distintos

`worker_pool.max_workers` es un control por función para admisión y cola. `runtime-daemons` es un control por runtime para ruteo entre sockets. Pueden combinarse, pero no resuelven el mismo problema.

## Cómo reproducir el benchmark de runtime-daemons

1. Arranca el fixture en modo native.
2. Corre cada runtime una vez con `runtime-daemons = 1`.
3. Repite con `runtime-daemons = 3`.
4. Mantén la misma concurrencia, warmup y cantidad de requests.
5. Guarda el resultado crudo en `tests/stress/results/`.

Ejemplo mínimo:

```bash
FN_RUNTIMES=node,python,php,rust \
FN_RUNTIME_DAEMONS=node=3,python=3,php=3,rust=3 \
fastfn dev --native tests/fixtures/worker-pool
```

Chequeo de validación:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
```

## Notas

- Los resultados dependen de CPU, carga de fondo y estado de instalación o build.
- El modo native y el modo Docker pueden dar resultados distintos.
- Un mejor promedio solo sirve si la tasa de error sigue siendo aceptable.

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
