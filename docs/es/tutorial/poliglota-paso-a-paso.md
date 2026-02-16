# Tutorial Poliglota (Paso a Paso)

Este tutorial arma una mini API donde funciones se llaman entre si en distintos runtimes.

Objetivo:

- Mantener un solo modelo de rutas (archivos estilo Next).
- Mezclar Node, Python, PHP y Rust en un mismo flujo.
- Componer todo desde un endpoint final.

Usaremos la carpeta:

- `examples/functions/polyglot-tutorial`

## Paso 0) Levantar el proyecto

```bash
bin/fastfn dev examples/functions
```

## Paso 1) Agregar endpoint inicial en Node

Archivo:

- `polyglot-tutorial/step-1/index.js`

Ruta:

- `GET /polyglot-tutorial/step-1`

Prueba:

```bash
curl -sS http://127.0.0.1:8080/polyglot-tutorial/step-1 | jq .
```

## Paso 2) Agregar endpoint dinamico en Python

Archivo:

- `polyglot-tutorial/step-2/index.py`

Ruta:

- `GET /polyglot-tutorial/step-2?name=<name>`

Prueba:

```bash
curl -sS 'http://127.0.0.1:8080/polyglot-tutorial/step-2?name=Ana' | jq .
```

## Paso 3) Agregar endpoint de score en PHP

Archivo:

- `polyglot-tutorial/step-3/index.php`

Ruta:

- `GET /polyglot-tutorial/step-3?name=<name>`

Prueba:

```bash
curl -sS 'http://127.0.0.1:8080/polyglot-tutorial/step-3?name=Ana' | jq .
```

## Paso 4) Agregar helper en Rust

Archivo:

- `polyglot-tutorial/step-4/index.rs`
- `polyglot-tutorial/step-4/get.status.rs` (alias)

Ruta:

- `GET /polyglot-tutorial/step-4`
- `GET /polyglot-tutorial/step-4/status` (alias)

Prueba:

```bash
curl -sS http://127.0.0.1:8080/polyglot-tutorial/step-4 | jq .
```

## Paso 5) Componer todo con un orquestador Node

Archivo:

- `polyglot-tutorial/step-5/index.js`

Ruta:

- `GET /polyglot-tutorial/step-5?name=<name>`

Que hace:

- Llama a pasos 1, 2, 3 y 4 via HTTP interno (`http://127.0.0.1:8080`).
- Une todas las respuestas en una sola salida.

Prueba:

```bash
curl -sS 'http://127.0.0.1:8080/polyglot-tutorial/step-5?name=Ana' | jq .
```

Forma esperada:

- `step: 5`
- `flow: [ ...cuatro respuestas... ]`
- `summary: "Polyglot pipeline completed for Ana"`

## Por que sirve este patron

- Permite migrar endpoint por endpoint sin cambiar el modelo de gateway.
- Permite dejar handlers rapidos en un runtime y logica pesada en otro.
- Sigue habiendo una sola superficie API y un solo OpenAPI.
