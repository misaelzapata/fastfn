# Contributing

Gracias por contribuir.

## Antes de empezar

Lee:

- `README.md`
- `docs/en/explanation/architecture.md`
- `docs/internal/TASK_QUEUE.md`

## Flujo recomendado

1. Crea una rama para tu cambio.
2. Implementa cambios pequenos y enfocados.
3. Asegura que el comportamiento publico quede documentado.
4. Ejecuta la suite completa:
   - `./scripts/test-all.sh`
   - `./scripts/coverage.sh`
5. Abre PR con:
   - resumen del cambio
   - riesgos/regresiones posibles
   - plan de pruebas ejecutadas

## Reglas tecnicas

- No introducir imports/paths dinamicos desde input de usuario.
- No permitir lectura/escritura fuera de `srv/fn/functions`.
- Mantener contrato runtime:
  - request: `{fn, version, event}`
  - response: `{status, headers, body}` o base64 para binario.
- Mantener `invoke.methods` como fuente de verdad para:
  - gateway (`405`)
  - `/_fn/invoke`
  - OpenAPI/Swagger
- Mantener routing publico consistente:
  - rutas publicas mapeadas (filesystem/manifest) sin prefijos especiales
  - versionado por `/<name>@<version>` cuando aplique

## Checklist de PR

- [ ] tests unit pasan
- [ ] tests integracion pasan
- [ ] coverage actualizado y sin regressions grandes
- [ ] README actualizado si cambio API/flujo
- [ ] docs/en/explanation/architecture.md actualizado si cambio arquitectura
- [ ] sin secretos hardcodeados en ejemplos

## CI

Workflow GitHub Actions:

- `.github/workflows/ci.yml`

Stages:

1. `unit`: tests Python + Node + cobertura.
2. `e2e`: suite completa (`./scripts/test-all.sh`) con Docker Compose/OpenResty.
