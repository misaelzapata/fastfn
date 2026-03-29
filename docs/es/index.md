---
hide:
  - toc
---

<style>
.md-content .md-typeset h1 { display: none; }
</style>

<p align="center">
  <img src="../logo.png" alt="FastFN Logo" width="180">
</p>
<p align="center">
    <em>Plataforma FaaS self-hosted, de alto rendimiento, fácil de aprender y rápida de programar</em>
</p>
<p align="center">
<a href="https://github.com/misaelzapata/fastfn" target="_blank">
    <img src="https://img.shields.io/badge/GitHub-misaelzapata%2Ffastfn-181717?logo=github&logoColor=white" alt="GitHub">
</a>
<a href="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml" target="_blank">
    <img src="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml/badge.svg" alt="Docs">
</a>
<a href="https://codecov.io/gh/misaelzapata/fastfn" target="_blank">
    <img src="https://codecov.io/gh/misaelzapata/fastfn/graph/badge.svg" alt="Coverage">
</a>
</p>

<hr />
<p><strong>Documentación</strong>: <a href="https://fastfn.dev/es/" target="_blank">https://fastfn.dev/es/</a></p>
<p><strong>Código Fuente</strong>: <a href="https://github.com/misaelzapata/fastfn" target="_blank">https://github.com/misaelzapata/fastfn</a></p>
<hr />

<p>FastFN es un servidor FaaS self-hosted, orientado al CLI, para construir APIs con enrutamiento por sistema de archivos, servir SPA + API juntos y mantener todo el proyecto fácil de correr en local o en una VM.</p>

<p>Las características clave son:</p>
<ul>
<li><strong>Rápido de programar</strong>: Suelta un archivo, obtén un endpoint y mantén el árbol de rutas cerca del código que lo atiende.</li>
<li><strong>Documentación Automática</strong>: Documentación de API interactiva (Swagger UI) generada automáticamente desde tu código.</li>
<li><strong>Poder Políglota</strong>: Usa la mejor herramienta para el trabajo. Python, Node, PHP, Lua, Rust o Go en un solo proyecto.</li>
<li><strong>SPA + API</strong>: Monta una carpeta configurable como <code>public/</code> o <code>dist/</code> en <code>/</code> y deja handlers API simples al lado.</li>
</ul>

<p align="center">
  <img src="../demo.gif" alt="Demo terminal de FastFN" width="100%">
</p>

<p align="center">
  <a href="./tutorial/primeros-pasos.md"><strong>Inicio Rápido</strong></a>
  &bull;
  <a href="./tutorial/spa-y-api-juntas.md"><strong>SPA + API</strong></a>
  &bull;
  <a href="./como-hacer/ejecutar-como-servicio-linux.md"><strong>Servicio Linux</strong></a>
  &bull;
  <a href="./articulos/assets-publicos-estilo-cloudflare.md"><strong>Assets Públicos</strong></a>
</p>

## Lo que obtienes en los primeros 5 minutos

- Crear un archivo de función y servirlo localmente.
- Llamar la ruta inmediatamente con `curl`.
- Abrir la documentación automática en `http://127.0.0.1:8080/docs`.
- Seguir creciendo la misma API con Python, Node, PHP, Lua y Rust bajo un solo árbol de URLs.
- Servir una SPA simple y una API pequeña juntas cuando ese sea el mejor encaje.

## Ruta de 5 minutos (orden recomendado)

1. Tutorial: [Inicio Rápido](./tutorial/primeros-pasos.md)
2. Tutorial: [Servir una SPA y una API juntas](./tutorial/spa-y-api-juntas.md)
3. Guía práctica: [Enrutamiento Zero-Config](./como-hacer/zero-config-routing.md)
4. Referencia: [API HTTP](./referencia/api-http.md)
5. Artículo: [Assets públicos estilo Cloudflare](./articulos/assets-publicos-estilo-cloudflare.md)
6. Guía práctica: [Ejecutar como servicio Linux](./como-hacer/ejecutar-como-servicio-linux.md)

Si estás leyendo esta página en GitHub y alguna tarjeta visual de más abajo no resuelve bien, usa estos links directos:

- [Inicio Rápido](https://fastfn.dev/es/tutorial/primeros-pasos/)
- [Servir una SPA y una API juntas](https://fastfn.dev/es/tutorial/spa-y-api-juntas/)
- [Enrutamiento Zero-Config](https://fastfn.dev/es/como-hacer/zero-config-routing/)
- [API HTTP](https://fastfn.dev/es/referencia/api-http/)
- [Assets públicos estilo Cloudflare](https://fastfn.dev/es/articulos/assets-publicos-estilo-cloudflare/)
- [Ejecutar como servicio Linux](https://fastfn.dev/es/como-hacer/ejecutar-como-servicio-linux/)

## Comienza en 60 segundos

### 1. Suelta un archivo, obtén un endpoint

Crea un archivo llamado `hello.js` (o `.py`, `.php`, `.rs`):

=== "Node.js"
    ```js
    // hello.js
    exports.handler = async (event) => ({
      message: '¡Hola desde FastFN!',
      query: event.query || {},
      runtime: 'node',
    });
    ```

=== "Python"
    ```python
    # hello.py
    def handler(event):
        name = event.get("query", {}).get("name", "Mundo")
        return {
            "status": 200,
            "body": {"hello": name, "runtime": "python"}
        }
    ```

### 2. Ejecuta el servidor

```bash
fastfn dev
```

### 3. Llama a tu API

```bash
curl "http://127.0.0.1:8080/hello?name=Misael"
```

Respuesta esperada:

```json
{
    "message": "¡Hola desde FastFN!",
    "query": {
        "name": "Misael"
    },
    "runtime": "node"
}
```

Sin `serverless.yml`. Sin código repetitivo del framework. Las rutas de archivos se descubren automáticamente.

### 4. Abre la documentación generada

- Swagger UI: `http://127.0.0.1:8080/docs`
- OpenAPI JSON: `http://127.0.0.1:8080/openapi.json`

Si quieres el camino más corto desde cero hasta un uso parecido a producción, sigue este orden:

1. [Inicio Rápido](./tutorial/primeros-pasos.md)
2. [Desde Cero](./tutorial/desde-cero/index.md)
3. [API HTTP](./referencia/api-http.md)
4. [Desplegar a Producción](./como-hacer/desplegar-a-produccion.md)

## Documentación

Esta documentación está estructurada para ayudarte a aprender FastFN paso a paso, desde tu primera ruta hasta el despliegue en producción.

<div class="grid cards" markdown>

-   **Primeros Pasos**
    
    Instala FastFN y construye tu primer endpoint de API en 5 minutos.
    
    [Inicio Rápido](./tutorial/primeros-pasos.md)

-   **Conceptos Centrales**
    
    Entiende cómo funciona el enrutamiento por sistema de archivos y la configuración.
    
    [Enrutamiento por Sistema de Archivos](./tutorial/routing.md)

-   **Matriz de Soporte**
    
    Revisa qué ofrece FastFN de fábrica y dónde encaja mejor.
    
    [Explorar Matriz de Soporte](./explicacion/matriz-soporte-protocolos-avanzados.md)

-   **Aprende (El Curso)**
    
    Un curso completo de 4 partes para construir una API del mundo real desde cero.
    
    [Comenzar el Curso](./tutorial/desde-cero/index.md)

-   **Guías Prácticas**
    
    Recetas prácticas para despliegue, autenticación y más.
    
    [Ver Guías](./como-hacer/desplegar-a-produccion.md)

</div>

## Características Clave

*   **Enrutamiento Mágico**: `[id]`, `[...slug]` soportados de fábrica.
*   **Gateway de bajo overhead**: OpenResty valida políticas y despacha sobre sockets unix locales.
*   **Basado en Estándares**: Generación de OpenAPI 3.1 totalmente compatible para todas tus funciones.
*   **Primero el Desarrollador**: La plataforma se adapta a tus archivos, no al revés.
*   **Multi-Runtime**: Python, Node, PHP, Lua y Rust con un solo contrato.

## Enlaces Rápidos

*   [API HTTP](./referencia/api-http.md)
*   [Servir una SPA y una API juntas](./tutorial/spa-y-api-juntas.md)
*   [Assets públicos estilo Cloudflare](./articulos/assets-publicos-estilo-cloudflare.md)
*   [Ejecutar como servicio Linux](./como-hacer/ejecutar-como-servicio-linux.md)
*   [Contrato de Runtime](./referencia/contrato-runtime.md)
*   [Inputs y Respuestas Tipadas](./tutorial/inputs-y-respuestas-tipadas.md)
*   [Funciones de Ejemplo](./referencia/funciones-ejemplo.md)
*   [Matriz de Soporte (Protocolos Avanzados)](./explicacion/matriz-soporte-protocolos-avanzados.md)
*   [Recetas Operativas](./como-hacer/recetas-operativas.md)
*   [Checklist de seguridad](./como-hacer/checklist-seguridad-produccion.md)

## Tutoriales Extendidos

*   [Construir una API completa (end-to-end)](./tutorial/construir-api-completa.md)
*   [Patrones QR en Python + Node + PHP + Lua (aislamiento de dependencias)](./tutorial/qr-python-node.md)
*   [Versionado y despliegue](./tutorial/versionado-y-rollout.md)
*   [Autenticación y secretos](./tutorial/auth-y-secretos.md)

## Guías Visuales

*   [Flujos visuales](./explicacion/flujos-visuales.md)
