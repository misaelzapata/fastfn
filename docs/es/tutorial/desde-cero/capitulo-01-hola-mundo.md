# Capitulo 1 - Hola Mundo (Primera funcion)

Objetivo: crear un solo archivo y llamarlo desde el browser o `curl`, usando el routing simplificado.

## Que estas construyendo

Una funcion llamada `hello-world`.

Eso significa que tu URL va a ser:

- `/hello-world`

## Paso 1: crea una carpeta de proyecto

```bash
mkdir mis-funciones
cd mis-funciones
```

## Paso 2: crea el archivo de la funcion

Crea la carpeta y el archivo:

```bash
mkdir -p functions/hello-world
touch functions/hello-world/get.js
```

Pega este codigo en `functions/hello-world/get.js`:

```js
exports.handler = async (event) => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    ok: true,
    message: "Hola FastFN",
    method: event.method,
    path: event.path,
  }),
});
```

## Paso 3: inicia el servidor de desarrollo

```bash
fastfn dev functions
```

Deberias ver que esta corriendo en `http://127.0.0.1:8080`.

## Paso 4: llama tu funcion

Abre:

- `http://127.0.0.1:8080/hello-world`

Salida esperada:

```json
{"ok":true,"message":"Hola FastFN","method":"GET","path":"/hello-world"}
```

## Troubleshooting

1. Modo portable: confirma que Docker Desktop esta corriendo.
2. Confirma el path: `functions/hello-world/get.js`.
3. Modo native: intenta `fastfn dev --native functions` y confirma que OpenResty esta instalado.

