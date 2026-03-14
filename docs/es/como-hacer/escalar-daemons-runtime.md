# Escalar daemons de runtime

> Estado verificado al **14 de marzo de 2026**.

## Vista rápida

- Complejidad: Intermedia
- Tiempo típico: 15-25 minutos
- Úsala cuando: un runtime es el cuello de botella y quieres más de un socket real para ese runtime
- Resultado: FastFN arranca varias instancias de daemon y reparte tráfico entre sockets sanos con `round_robin`

## Qué cambia

`runtime-daemons` es una configuración global del runtime. No es lo mismo que `worker_pool.max_workers`.

- `runtime-daemons` agrega más procesos y sockets para un runtime.
- `worker_pool` sigue en el gateway y controla admisión y cola por función.

Usa `runtime-daemons` cuando quieres más destinos reales para un runtime como Node o Python.

## Paso 1: Agrega los counts

`fastfn.json`

```json
{
  "functions-dir": "functions",
  "runtime-daemons": {
    "node": 3,
    "python": 3
  }
}
```

También puedes usar la forma string:

```json
{
  "runtime-daemons": "node=3,python=3"
}
```

Notas:

- El valor por defecto es `1`.
- `lua` ignora counts porque corre dentro de OpenResty.
- Esta opción solo tiene efecto en runtimes externos.

## Paso 2: Elige binarios del host si hace falta

Si el modo native debe usar un intérprete o herramienta concreta, define `runtime-binaries`:

```json
{
  "runtime-binaries": {
    "python": "python3.12",
    "node": "node20",
    "openresty": "/opt/homebrew/bin/openresty"
  }
}
```

Regla importante:

- FastFN elige un ejecutable por clave.
- Todos los daemons de ese grupo usan el mismo ejecutable configurado.

Si prefieres variables de entorno:

```bash
export FN_PYTHON_BIN=python3.12
export FN_NODE_BIN=node20
export FN_OPENRESTY_BIN=/opt/homebrew/bin/openresty
```

## Paso 3: Arranca la pila

Modo native:

```bash
FN_RUNTIMES=node,python fastfn dev --native functions
```

Modo Docker:

```bash
FN_RUNTIME_DAEMONS=node=3,python=3 fastfn dev functions
```

## Paso 4: Confirma el ruteo y la salud

Revisa health:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
```

Qué deberías ver:

- `routing: "round_robin"` en runtimes con más de un socket
- un array `sockets` con una entrada por daemon
- `up: true` tanto a nivel runtime como a nivel socket

Si habilitaste debug headers en `fn.config.json`, las respuestas también pueden incluir:

- `X-Fn-Runtime-Routing`
- `X-Fn-Runtime-Socket-Index`

Comportamiento importante para validar:

- un runtime puede seguir disponible aunque un socket de daemon quede caído
- `/_fn/health` muestra ese socket degradado dentro de `sockets`
- el tráfico sigue entrando por los sockets sanos restantes

El repositorio ya trae una prueba de integración para este escenario:

```bash
bash tests/integration/test-runtime-daemon-failover.sh
```

## Paso 5: Mide antes de dejarlo fijo

No des por hecho que más daemons siempre mejoran el resultado.

En el benchmark actual del **14 de marzo de 2026**:

- Native:
  - Node mejoró `12.1%`
  - Python mejoró `64.8%`
  - Rust mejoró `20.0%`
  - PHP empeoró `9.2%`
- Docker:
  - Node mejoró `8.9%`
  - Python mejoró `76.7%`
  - PHP mejoró `27.0%`
  - Rust mejoró `4.5%`

Puedes ver el detalle completo aquí:

- [Benchmarks de rendimiento](../explicacion/benchmarks-rendimiento.md)

## Override avanzado: sockets explícitos

Si necesitas controlar exactamente la ubicación de los sockets, usa `FN_RUNTIME_SOCKETS`:

```bash
export FN_RUNTIME_SOCKETS='{"node":["unix:/tmp/fastfn/node-1.sock","unix:/tmp/fastfn/node-2.sock"],"python":"unix:/tmp/fastfn/python.sock"}'
fastfn dev --native functions
```

Este override gana sobre `runtime-daemons`.

## Validación

Secuencia rápida:

```bash
curl -sS http://127.0.0.1:8080/_fn/health | jq '.runtimes'
curl -i http://127.0.0.1:8080/hola
```

Esperado:

- health responde `200`
- el runtime objetivo muestra la cantidad de sockets esperada
- la ruta pública sigue devolviendo la misma respuesta funcional

## Troubleshooting

- Si parece que el count no tuvo efecto, confirma que no estás intentando escalar `lua`.
- Si un runtime queda caído, revisa primero la selección de binario (`FN_*_BIN` o `runtime-binaries`).
- Si solo aparece un socket, confirma que no exista un override explícito en `FN_RUNTIME_SOCKETS`.
- Si un socket aparece caído pero el runtime sigue en `up=true`, el tráfico debería continuar por los sockets restantes mientras el supervisor reinicia el daemon fallado.
- Si el rendimiento empeora, deja ese runtime en `1` y vuelve a medir más adelante con una carga más representativa.

## Enlaces relacionados

- [Configuración global](../referencia/config-fastfn.md)
- [Especificación de funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Arquitectura](../explicacion/arquitectura.md)
- [Benchmarks de rendimiento](../explicacion/benchmarks-rendimiento.md)
- [Plomería runtime/plataforma](./plomeria-runtime-plataforma.md)
- [Ejecutar y probar](./ejecutar-y-probar.md)
