# Benchmarks de Rendimiento

Esta página publica snapshots reproducibles de benchmarks para FastFN.

Objetivos del reporte:

- publicar carga y límites, no solo un número de RPS
- publicar mezcla de estados (`200`, `429`, `5xx`)
- publicar comandos reproducibles
- publicar artefactos crudos

## Fast-path (poliglota “Hola Mundo”)

Snapshot: **martes 17 de febrero de 2026**.

Carga:

- Endpoints (tutorial poliglota):
  - `GET /step-1` (Node)
  - `GET /step-2` (Python)
  - `GET /step-3` (PHP)
  - `GET /step-4` (Rust)
- Runner:
  - `tests/stress/benchmark-fastpath.py`
- Medición:
  - requests por punto: `4000`
  - matriz de concurrencia: `1,2,4,8,16,20,24,32`

Resultados (mejor punto limpio: **solo `200`**):

| Runtime | Endpoint | Mejor punto limpio |
|---|---|---:|
| Node | `/step-1` | `1772.69 RPS` (`c=16`) |
| Python | `/step-2` | `878.73 RPS` (`c=16`) |
| PHP | `/step-3` | `562.90 RPS` (`c=20`) |
| Rust | `/step-4` | `866.69 RPS` (`c=20`) |

Artefacto crudo:

- `tests/stress/results/2026-02-17-fastpath-default.json`

### Cómo reproducir

Arranca la app del tutorial poliglota:

```bash
bin/fastfn dev examples/functions/polyglot-tutorial
```

Ejecuta el benchmark:

```bash
python3 tests/stress/benchmark-fastpath.py \
  --base-url http://127.0.0.1:8080 \
  --profile default \
  --total 4000 \
  --concurrency-set 1,2,4,8,16,20,24,32
```

## Carga QR (CPU-bound)

La generación de QR es intencionalmente más pesada que rutas fast-path de JSON.

Runner:

- `cli/benchmark-qr.sh`

Artefactos crudos:

- `tests/stress/results/` (JSON con fecha)

## Notas

- Los números dependen del entorno (CPU host, Docker, carga local).
- Tómalos como baseline y tendencia, no como claim universal.
