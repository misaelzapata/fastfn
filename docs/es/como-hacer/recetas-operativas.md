# Recetas operativas (copiar y pegar)

Recetas practicas con objetivo, comando, resultado esperado y diagnostico rapido.

## Receta 1: salud de plataforma

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health'
```

Esperado: runtimes estables `python`, `node`, `php` y `lua` con `health.up=true` (`rust`/`go` cuando estén habilitados).

Si `curl` no conecta pero el stack esta levantado (y/o `wget` te funciona), probá:

```bash
# forzar IPv4
curl -4 -sS 'http://127.0.0.1:8080/_fn/health'

# ignorar proxies si tu entorno los tiene
curl --noproxy '*' -sS 'http://127.0.0.1:8080/_fn/health'
```

En entornos "sandbox" donde el loopback del host esta bloqueado, hacé el request desde adentro del contenedor:

```bash
docker compose exec -T openresty sh -lc "curl -sS 'http://127.0.0.1:8080/_fn/health'"
```

## Receta 2: catalogo de funciones descubiertas

```bash
curl -sS 'http://127.0.0.1:8080/_fn/catalog'
```

Uso: saber que funciones existen y con que politica efectiva.

## Receta 3: invocacion GET con query

```bash
curl -sS 'http://127.0.0.1:8080/fn/echo?key=test'
```

Esperado (aprox):

```json
{"key":"test","query":{"key":"test"},"context":{"user":null}}
```

## Receta 4: versionado (`@v2`)

```bash
curl -sS 'http://127.0.0.1:8080/fn/hello@v2?name=NodeWay'
```

Uso: rollout progresivo sin romper version default.

## Receta 4b: probar PHP y Rust

```bash
curl -sS 'http://127.0.0.1:8080/fn/php_profile?name=PHP'
curl -sS 'http://127.0.0.1:8080/fn/rust_profile?name=Rust'
```

## Receta 4c: probar rutas (patrón Python + Node + PHP + Lua)

```bash
curl -sS 'http://127.0.0.1:8080/fn/qr?text=PythonQR' -o qr-python.svg
curl -sS 'http://127.0.0.1:8080/fn/qr@v2?text=NodeQR' -o qr-node.png
```

## Receta 5: forzar 405 por metodo no permitido

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X POST 'http://127.0.0.1:8080/fn/echo?key=test'
```

Esperado: `405`.

## Receta 6: actualizar metodos permitidos en caliente

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=node&name=node_echo' \
  -X PUT -H 'Content-Type: application/json' \
  --data '{"invoke":{"methods":["GET","POST","PUT","DELETE"]}}'
```

Verificar:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X PUT 'http://127.0.0.1:8080/fn/node_echo?name=x'
```

## Receta 7: inyectar `context` desde `/_fn/invoke`

```bash
curl -sS 'http://127.0.0.1:8080/_fn/invoke' \
  -X POST -H 'Content-Type: application/json' \
  --data '{
    "name":"echo",
    "method":"GET",
    "query":{"key":"ctx"},
    "context":{"trace_id":"abc-123","tenant":"demo"}
  }'
```

Esperado: el handler recibe `event.context.user.trace_id`.

## Receta 8: crear funcion por API

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=node&name=demo_recipe' \
  -X POST -H 'Content-Type: application/json' \
  --data '{"methods":["GET"],"summary":"Demo recipe"}'
```

## Receta 9: editar codigo por API

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-code?runtime=node&name=demo_recipe' \
  -X PUT -H 'Content-Type: application/json' \
  --data '{"code":"exports.handler = async (event) => ({ status: 200, headers: { \"Content-Type\": \"application/json\" }, body: JSON.stringify({ ok: true, query: event.query || {} }) });\n"}'
```

Validar:

```bash
curl -sS 'http://127.0.0.1:8080/fn/demo_recipe?name=RecipeOK'
```

## Receta 10: respuestas HTML/CSV/PNG

```bash
curl -i -sS 'http://127.0.0.1:8080/fn/html_demo?name=Web' | head -n 10
curl -i -sS 'http://127.0.0.1:8080/fn/csv_demo?name=Alice' | head -n 12
curl -sS 'http://127.0.0.1:8080/fn/png_demo' --output out.png
file out.png
```

## Receta 11: recargar discovery

```bash
curl -sS 'http://127.0.0.1:8080/_fn/reload' -X POST
```

Uso: despues de crear/borrar funciones manualmente en filesystem.

## Receta 12: limpieza de demos

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=node&name=demo_recipe' -X DELETE
```

## Diagnostico express

Si algo falla:

```bash
docker compose logs --tail=200 openresty
```
