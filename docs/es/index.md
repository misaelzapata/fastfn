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

> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.

<p>FastFN es un framework serverless moderno y rápido (de alto rendimiento) para construir APIs con múltiples lenguajes basado en enrutamiento por sistema de archivos.</p>

<p>Las características clave son:</p>
<ul>
<li><strong>Rápido de programar</strong>: Incrementa la velocidad de desarrollo de funcionalidades entre un 200% y 300%. Suelta un archivo, obtén un endpoint.</li>
<li><strong>Documentación Automática</strong>: Documentación de API interactiva (Swagger UI) generada automáticamente desde tu código.</li>
<li><strong>Poder Políglota</strong>: Usa la mejor herramienta para el trabajo. IA en Python, IO en Node, lógica de pegamento en Lua, rendimiento en Rust.</li>
</ul>

## Comienza en 60 segundos

### 1. Suelta un archivo, obtén un endpoint

Crea un archivo llamado `hello.js` (o `.py`, `.php`, `.rs`):

=== "Node.js"
    ```js
    // hello.js
    exports.handler = async () => "Hola Mundo";
    ```

=== "Python"
    ```python
    # hello.py
    def handler(event):
        return {"hola": "mundo"}
    ```

=== "PHP"
    ```php
    <?php
    function handler($event) {
        return "Hola Mundo";
    }
    ```

=== "Lua"
    ```lua
    function handler(event)
      return { hola = "mundo" }
    end
    ```

=== "Go"
    ```go
    package main

    func handler(event map[string]interface{}) map[string]interface{} {
        return map[string]interface{}{
            "status": 200,
            "body": "Hola Mundo",
        }
    }
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn handler(_event: Value) -> Value {
        json!({
            "status": 200,
            "body": "Hola Mundo"
        })
    }
    ```

### 2. Ejecuta el servidor

```bash
fastfn dev
```

### 3. Llama a tu API

<p align="center">
  <img src="../assets/screenshots/browser-hello-world.png" alt="Vista completa en navegador de /hello" width="100%">
</p>

<p align="center">
  <img src="../demo.gif" alt="FastFN Terminal Demo" width="100%">
</p>

Sin `serverless.yml`. Sin código repetitivo del framework. Las rutas de archivos se descubren automáticamente.

## Documentación

Esta documentación está estructurada para ayudarte a aprender FastFN paso a paso, desde tu primera ruta hasta el despliegue en producción.

<div class="grid cards" markdown>

-   **Primeros Pasos**
    
    Instala FastFN y construye tu primer endpoint de API en 5 minutos.
    
    [Inicio Rápido](./tutorial/primeros-pasos.md)

-   **Conceptos Centrales**
    
    Entiende cómo funciona el enrutamiento por sistema de archivos y la configuración.
    
    [Enrutamiento por Sistema de Archivos](./tutorial/routing.md)

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

*   [Definición de API HTTP](./referencia/api-http.md)
*   [Contrato de Runtime](./referencia/contrato-runtime.md)
*   [Funciones Integradas](./referencia/funciones-ejemplo.md)
*   [Recetas Operacionales](./como-hacer/recetas-operativas.md)
*   [Lista de Confianza de Seguridad](./como-hacer/checklist-seguridad-produccion.md)

## Tutoriales Extendidos

*   [Construir una API completa (end-to-end)](./tutorial/construir-api-completa.md)
*   [Patrones QR en Python + Node + PHP + Lua (aislamiento de dependencias)](./tutorial/qr-python-node.md)
*   [Versionado y despliegue](./tutorial/versionado-y-rollout.md)
*   [Autenticación y secretos](./tutorial/auth-y-secretos.md)

## Guías Visuales

*   [Flujos visuales](./explicacion/flujos-visuales.md)

## Ver también

- [Especificación de Funciones](referencia/especificacion-funciones.md)
- [Referencia API HTTP](referencia/api-http.md)
- [Checklist Ejecutar y Probar](como-hacer/ejecutar-y-probar.md)
