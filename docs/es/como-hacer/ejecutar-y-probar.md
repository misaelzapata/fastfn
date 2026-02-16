# Ejecutar y probar

Checklist reproducible para validar la plataforma en local.

## Que valida

- arranque en Docker
- salud de runtimes
- respuesta de rutas publicas
- disponibilidad de docs
- smoke + integracion + stress smoke

## Requisitos

- Docker Desktop activo
- `docker compose` disponible
- puerto `8080` libre

## 1) Levantar plataforma

```bash
docker compose up -d --build
```

## 2) Esperar salud

```bash
for i in $(seq 1 60); do
  curl -sS 'http://127.0.0.1:8080/_fn/health' >/tmp/fn-health.json 2>/dev/null && break
  sleep 1
done
cat /tmp/fn-health.json
```

Esperado: `python.health.up=true`, `node.health.up=true`, `php.health.up=true` y `rust.health.up=true`.

## 3) Verificar rutas publicas

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello?name=World'
curl -sS 'http://127.0.0.1:8080/fn/hello@v2?name=NodeWay'
curl -sS 'http://127.0.0.1:8080/fn/echo?key=test'
curl -sS 'http://127.0.0.1:8080/fn/qr?text=PythonQR' -o /tmp/qr-python.svg
curl -sS 'http://127.0.0.1:8080/fn/qr@v2?text=NodeQR' -o /tmp/qr-node.png
curl -sS 'http://127.0.0.1:8080/fn/php-profile?name=PHP'
curl -sS 'http://127.0.0.1:8080/fn/rust-profile?name=Rust'
```

Chequeo opcional de aislamiento de dependencias:

```bash
docker compose exec -T openresty sh -lc "rm -rf /app/srv/fn/functions/python/qr/.deps /app/srv/fn/functions/node/qr/v2/node_modules"
curl -sS 'http://127.0.0.1:8080/fn/qr?text=PythonQR' -o /tmp/qr-python.svg
curl -sS 'http://127.0.0.1:8080/fn/qr@v2?text=NodeQR' -o /tmp/qr-node.png
docker compose exec -T openresty sh -lc "ls -la /app/srv/fn/functions/python/qr/.deps | head"
docker compose exec -T openresty sh -lc "ls -la /app/srv/fn/functions/node/qr/v2/node_modules | head"
```

## 4) Verificar endpoints de docs

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | head -c 300
```

- Swagger: [http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs)
- Console: [http://127.0.0.1:8080/console](http://127.0.0.1:8080/console)

## 5) Ejecutar checks empaquetados

```bash
./scripts/smoke.sh
./scripts/curl-examples.sh
./scripts/stress.sh
```

## 6) Suite completa

```bash
./scripts/test-all.sh
```

## 7) Snapshots de benchmark QR

```bash
./scripts/benchmark-qr.sh default
./scripts/benchmark-qr.sh no-throttle
```

Los resultados se guardan en `tests/stress/results/`.

Reporte de referencia:

- `docs/es/explicacion/benchmarks-rendimiento.md`

## 8) Apagar limpio

```bash
docker compose down --remove-orphans
```

## Nota sobre root de funciones configurable

El root de discovery se configura con `FN_FUNCTIONS_ROOT`.

Orden de resolucion:

1. `FN_FUNCTIONS_ROOT`
2. `/app/srv/fn/functions`
3. `$PWD/srv/fn/functions`
4. `/srv/fn/functions`
