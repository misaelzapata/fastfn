# Primeros pasos

Esta guia te muestra el flujo completo de FastFN con validaciones reales.

Vas a:

1. compilar el CLI
2. levantar el runtime
3. enviar trafico HTTP real
4. validar salud, ruteo y OpenAPI

Si vienes de FastAPI o de rutas API de Next.js, el modelo es familiar: los archivos definen rutas y luego la capa de config/politica ajusta comportamiento.

## Antes de empezar

Desde la raiz del repo:

```bash
make build-cli
```

Esto genera `./bin/fastfn`.

Modos de ejecucion:

- `docker` (default, recomendado para primera corrida): `./bin/fastfn dev .`
- `native` (requiere OpenResty en PATH): `./bin/fastfn dev --native .`

Referencias relacionadas:

- [Flags del CLI](../referencia/cli-reference.md)
- [Desplegar en produccion](../como-hacer/desplegar-a-produccion.md)
- [Arquitectura](../explicacion/arquitectura.md)

## 1) Crear una primera funcion

Crea una funcion minima:

```bash
./bin/fastfn init hello --template node
```

Se crea una carpeta con:

- `fn.config.json` (config y politica de la funcion)
- `handler.js` (handler runtime)

Referencia:

- [Especificacion de funciones](../referencia/especificacion-funciones.md)
- [Configuracion fastfn.json](../referencia/config-fastfn.md)

## 2) Levantar FastFN

Modo Docker:

```bash
./bin/fastfn dev .
```

Modo Native:

```bash
./bin/fastfn dev --native .
```

Que inicia internamente:

1. gateway (OpenResty)
2. daemons de runtime (Node/Python/PHP/Lua y runtimes experimentales opcionales)
3. discovery de archivos y generacion del mapa de rutas

Mas detalle:

- [Flujo de invocacion](../explicacion/flujo-invocacion.md)
- [Contrato runtime](../referencia/contrato-runtime.md)

## 3) Verificar salud del sistema

En otra terminal:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health' | jq
```

Esperado:

- gateway accesible
- cada runtime habilitado con `"up": true`

Si un runtime aparece caido:

- revisar dependencias faltantes en modo native (`openresty`, `node`, `python3`, etc.)
- revisar daemon de Docker en modo docker

Rutas de troubleshooting:

- [Ejecutar y probar](../como-hacer/ejecutar-y-probar.md)
- [Recetas operativas](../como-hacer/recetas-operativas.md)

## 4) Enviar la primera request

```bash
curl -i 'http://127.0.0.1:8080/hello?name=Mundo'
```

Esto valida:

1. resolucion de ruta publica
2. dispatch gateway -> socket runtime
3. normalizacion de salida del handler a respuesta HTTP

Modelo de ruteo:

- [Especificacion de funciones](../referencia/especificacion-funciones.md)
- [Arquitectura](../explicacion/arquitectura.md)

## 5) Validar consistencia de docs y mapa de rutas

OpenAPI:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/openapi.json' | jq '.paths | keys'
```

Catalogo:

```bash
curl -sS 'http://127.0.0.1:8080/_fn/catalog' | jq '{mapped_routes, mapped_route_conflicts}'
```

Esperado:

- la ruta aparece en catalogo y OpenAPI
- `mapped_route_conflicts` vacio

Referencias:

- [API HTTP](../referencia/api-http.md)
- [Funciones de ejemplo](../referencia/funciones-ejemplo.md)

## 6) Apagar limpio

Modo Docker:

```bash
docker compose down --remove-orphans
```

Modo Native:

- detener con `Ctrl+C` en la terminal de `fastfn dev --native`.

## Siguientes lecturas

- [Construir API completa](./construir-api-completa.md)
- [Ejecutar y probar (validacion completa)](../como-hacer/ejecutar-y-probar.md)
- [Desplegar a produccion](../como-hacer/desplegar-a-produccion.md)
