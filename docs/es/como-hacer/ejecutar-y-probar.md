# Ejecutar y probar

Checklist practico para validar FastFN en local.

## Que valida

- arranque en modo portable (Docker)
- salud de runtimes
- respuesta de rutas publicas
- OpenAPI + Swagger UI
- unit + integracion + UI E2E

## Requisitos

- Docker Desktop activo
- `bin/fastfn` compilado o instalado
- puerto `8080` libre

## 1) Pipeline automatico (recomendado)

```bash
bash scripts/ci/test-pipeline.sh
```

Si pasa, la plataforma esta OK.

## 2) Verificacion manual

### Levantar demo

```bash
bin/fastfn dev examples/functions/next-style
```

### Salud

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health' | jq
```

### Rutas publicas

```bash
curl -sS 'http://127.0.0.1:8080/hello?name=World'
```

Chequeo opcional de deps (auto-install + cold start):

```bash
bin/fastfn dev examples/functions

curl -sS 'http://127.0.0.1:8080/qr?text=PythonQR' -o /tmp/qr-python.svg
curl -sS 'http://127.0.0.1:8080/qr@v2?text=NodeQR' -o /tmp/qr-node.png

# Forzar reinstalacion (estos folders se crean en runtime):
rm -rf examples/functions/python/qr/.deps
rm -rf examples/functions/node/qr/v2/node_modules
```

## 3) Docs

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | head -c 300
```

- Swagger: [http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs)
- Console: [http://127.0.0.1:8080/console](http://127.0.0.1:8080/console)

## 4) Apagar limpio

```bash
docker compose down --remove-orphans
```

## 5) Root de funciones

FastFN escanea el directorio que le pasas a `fastfn dev`.

Recomendado:

- Poner tus funciones en `functions/` y correr: `fastfn dev functions`
- O setear el default en `fastfn.json` con `functions-dir`
