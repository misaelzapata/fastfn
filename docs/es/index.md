---
hide:
  - toc
---

<style>
.md-content .md-typeset h1 { display: none; }
</style>

<p align="center">
  <img src="../logo.PNG" alt="FastFN Logo" width="180">
</p>
<p align="center">
    <em>Framework FastFN, alto rendimiento, fácil de aprender, rápido de programar, listo para producción</em>
</p>
<p align="center">
<a href="https://github.com/misaelzapata/fastfn" target="_blank">
    <img src="https://img.shields.io/badge/GitHub-misaelzapata%2Ffastfn-181717?logo=github&logoColor=white" alt="GitHub">
</a>
<a href="https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml" target="_blank">
    <img src="https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml/badge.svg" alt="CI">
</a>
<a href="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml" target="_blank">
    <img src="https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml/badge.svg" alt="Docs">
</a>
<a href="https://codecov.io/gh/misaelzapata/fastfn" target="_blank">
    <img src="https://codecov.io/gh/misaelzapata/fastfn/graph/badge.svg" alt="Coverage">
</a>
</p>

<hr />
<p><strong>Documentación</strong>: <a href="./index.md" target="_blank">https://misaelzapata.github.io/fastfn/es/</a></p>
<p><strong>Código Fuente</strong>: <a href="https://github.com/misaelzapata/fastfn" target="_blank">https://github.com/misaelzapata/fastfn</a></p>
<hr />

<p>FastFN es un framework serverless moderno y rápido (de alto rendimiento) para construir APIs con múltiples lenguajes basado en enrutamiento por sistema de archivos.</p>

<p>Las características clave son:</p>
<ul>
<li><strong>Rápido de programar</strong>: Incrementa la velocidad de desarrollo de funcionalidades entre un 200% y 300%. Suelta un archivo, obtén un endpoint.</li>
<li><strong>Documentación Automática</strong>: Documentación de API interactiva (Swagger UI) generada automáticamente desde tu código.</li>
<li><strong>Poder Políglota</strong>: Usa la mejor herramienta para el trabajo. IA en Python, IO en Node, lógica de pegamento en Lua, rendimiento en Rust.</li>
</ul>

## Lo que obtienes en los primeros 5 minutos

- Crear un archivo de función y servirlo localmente.
- Llamar la ruta inmediatamente con `curl`.
- Abrir la documentación automática en `http://127.0.0.1:8080/docs`.
- Seguir creciendo la misma API con Python, Node, PHP, Lua y Rust bajo un solo árbol de URLs.

## Ruta de 5 minutos (orden recomendado)

1. Tutorial: [Inicio Rápido](./tutorial/primeros-pasos.md)
2. Guía práctica: [Enrutamiento Zero-Config](./como-hacer/zero-config-routing.md)
3. Referencia: [API HTTP](./referencia/api-http.md)

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

<p align="center">
  <img src="../demo.gif" alt="FastFN Terminal Demo" width="100%">
</p>

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

-   **Matriz de Features**
    
    Revisa qué ofrece FastFN de fábrica y dónde encaja mejor.
    
    [Explorar Features](./explicacion/matriz-de-features.md)

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
*   [Contrato de Runtime](./referencia/contrato-runtime.md)
*   [Inputs y Respuestas Tipadas](./tutorial/inputs-y-respuestas-tipadas.md)
*   [Funciones de Ejemplo](./referencia/funciones-ejemplo.md)
*   [Matriz de Features](./explicacion/matriz-de-features.md)
*   [Recetas Operativas](./como-hacer/recetas-operativas.md)
*   [Checklist de seguridad](./como-hacer/checklist-seguridad-produccion.md)

## Tutoriales Extendidos

*   [Construir una API completa (end-to-end)](./tutorial/construir-api-completa.md)
*   [Patrones QR en Python + Node + PHP + Lua (aislamiento de dependencias)](./tutorial/qr-python-node.md)
*   [Versionado y despliegue](./tutorial/versionado-y-rollout.md)
*   [Autenticación y secretos](./tutorial/auth-y-secretos.md)

## Guías Visuales

*   [Flujos visuales](./explicacion/flujos-visuales.md)
