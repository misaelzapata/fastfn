# Servir una SPA y una API juntas

> Estado verificado al **27 de marzo de 2026**.
> Esto encaja muy bien con builds de frameworks como Vite/React, Vue, Svelte, Astro o cualquier bundle estático.

Uno de los setups más cómodos en FastFN es este:

- tu build SPA vive en `dist/` o `public/`
- tus handlers API viven en otra carpeta como `api/`
- FastFN sirve ambas cosas en la misma app con casi nada de configuración

Eso te deja sacar una SPA simple y una API pequeña juntas sin meter otra capa de proxy desde el día uno. Es una de las formas más limpias de mostrar el combo SPA + API de FastFN.

## Qué vamos a construir

- `/` sirve el shell SPA desde `dist/index.html`
- `/dashboard` vuelve al mismo shell SPA
- `/api/hello` devuelve JSON desde un handler normal de FastFN

## 1. Estructura del proyecto

```text
my-app/
├── fn.config.json
├── dist/
│   ├── index.html
│   └── assets/
│       └── app.js
└── api/
    └── hello/
        └── handler.js
```

`dist/` puede ser la salida de build de Vite, React, Vue, Svelte, Astro o cualquier otra SPA.

## 2. Configuración raíz

Crea un `fn.config.json` en la raíz:

```json
{
  "assets": {
    "directory": "dist",
    "not_found_handling": "single-page-application",
    "run_worker_first": false
  }
}
```

La idea principal es:

- `directory: "dist"` monta tu build SPA en `/`
- `single-page-application` hace que deep links como `/dashboard` vuelvan a `dist/index.html`
- `run_worker_first: false` mantiene todo simple cuando tu API vive bajo `/api/*`

## 3. Agrega una ruta API

Crea `api/hello/handler.js`:

```js
exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    ok: true,
    message: "hola desde FastFN",
  }),
});
```

Eso te da un handler normal en `/api/hello`.

Si despues este handler API necesita paquetes externos, prefiere agregar un `package.json` o `requirements.txt` explicito.
FastFN puede inferir dependencias en Python y Node, incluyendo backends opcionales como `pipreqs`, `detective` y `require-analyzer`, pero ese camino es mas lento y conviene usarlo como ayuda mientras arrancas.

## 4. Ejecuta la app

```bash
fastfn dev .
```

## 5. Prueba las tres URLs importantes

Shell SPA:

```bash
curl -I http://127.0.0.1:8080/
```

Deep link SPA:

```bash
curl -I -H 'Accept: text/html' http://127.0.0.1:8080/dashboard
```

Ruta API:

```bash
curl -sS http://127.0.0.1:8080/api/hello
```

Respuesta esperada:

```json
{
  "ok": true,
  "message": "hola desde FastFN"
}
```

## Por qué este setup es fuerte

- tu frontend sigue siendo una salida de build normal de framework
- tu API sigue siendo file-based y fácil de crecer
- el desarrollo local sigue siendo un solo comando
- la SPA y la API comparten la misma base URL
- no necesitas meter un reverse proxy custom para empezar

## Static-first vs worker-first

Para el caso más simple de SPA + API, deja tu API bajo `/api/*` y mantén `run_worker_first` en `false`.

Si quieres que las rutas runtime ganen antes que los archivos estáticos, cambia a:

```json
{
  "assets": {
    "directory": "dist",
    "not_found_handling": "single-page-application",
    "run_worker_first": true
  }
}
```

Eso sirve cuando el build del framework genera una ruta que debería perder frente a un handler.

## Ejemplos ejecutables

- `examples/functions/assets-spa-fallback`
- `examples/functions/assets-worker-first`
- `examples/functions/assets-static-first`

## Ver también

- [Enrutamiento Zero-Config](../como-hacer/zero-config-routing.md)
- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Assets públicos estilo Cloudflare](../articulos/assets-publicos-estilo-cloudflare.md)
