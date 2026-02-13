# Benchmarks de Rendimiento (carga QR)

Esta página publica un snapshot reproducible de benchmark QR para el **miércoles 11 de febrero de 2026**.

El formato sigue prácticas útiles que también usan plataformas como:

- [docs de n8n](https://docs.n8n.io/)
- [docs de Windmill](https://www.windmill.dev/docs)

Es decir:

- publicar carga y límites, no solo un número de RPS
- publicar mezcla de estados (`200`, `429`, `5xx`)
- publicar comandos reproducibles
- publicar artefactos crudos

## Perfiles medidos

Se corrieron dos perfiles:

1. **Política por defecto (guardrails ON)**  
   Sin tocar políticas de función (`max_concurrency=4` en ambas QR).
2. **Perfil de laboratorio sin throttling**  
   Configuración temporal para benchmark (`max_concurrency=512`) y observar degradación real sin límite de gateway.

## Carga usada

- Endpoints:
  - `/fn/qr` (Python SVG QR)
  - `/fn/qr@v2` (Node PNG QR)
- Dominios enviados en `text`:
  - `https://github.com/misaelzapata/fastfn`
  - `https://openai.com`
  - `https://example.org/path?x=1&y=2`
  - `https://n8n.io/workflows`
- Medición:
  - requests por corrida: `160` (perfil default), `240` (perfil sin throttling)
  - matriz de concurrencia:
    - default: `1,2,4,6,8`
    - sin throttling: `1,2,4,8,16,24,32`

## Resumen de resultados

### Política por defecto (guardrails ON)

| Endpoint | Primer punto con `429` | Mejor punto limpio (`200` only) |
|---|---:|---|
| `/fn/qr` | `c=6` | `155.07 RPS` (`c=2`, dominio `n8n.io`) |
| `/fn/qr@v2` | `c=6` | `119.14 RPS` (`c=4`, dominio `github.com`) |

Interpretación: el throttling aparece exactamente donde se espera por política (`max_concurrency=4`).

### Perfil sin throttling

| Endpoint | Puntos limpios (`200` only) | Pico limpio de RPS en esta corrida |
|---|---:|---|
| `/fn/qr` | `28/28` | `171.89 RPS` (`c=8`, `n8n.io`) |
| `/fn/qr@v2` | `28/28` | `149.58 RPS` (`c=24`, `github.com`) |

Interpretación: con `max_concurrency` alto, ambos endpoints quedaron limpios (`200` únicamente) en todo el rango probado hasta `c=32`.

## Artefactos crudos

- `tests/stress/results/2026-02-11-qr-default-policy.json`
- `tests/stress/results/2026-02-11-qr-no-throttle.json`

## Cómo reproducir

```bash
./scripts/benchmark-qr.sh default
./scripts/benchmark-qr.sh no-throttle
```

Ajuste opcional:

```bash
TOTAL=320 CONCURRENCY_SET=1,2,4,8,16,24,32,48 ./scripts/benchmark-qr.sh no-throttle
```

## Notas

- Los números dependen del entorno (CPU host, Docker, carga local).
- Tómalos como baseline técnico y tendencia, no como claim universal.
