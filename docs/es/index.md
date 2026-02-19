# Bienvenido a FastFN

[![GitHub](https://img.shields.io/badge/GitHub-misaelzapata%2Ffastfn-181717?logo=github&logoColor=white)](https://github.com/misaelzapata/fastfn)
[![CI](https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml/badge.svg)](https://github.com/misaelzapata/fastfn/actions/workflows/ci.yml)
[![Docs](https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml/badge.svg)](https://github.com/misaelzapata/fastfn/actions/workflows/docs.yml)
[![Coverage](https://codecov.io/gh/misaelzapata/fastfn/graph/badge.svg)](https://codecov.io/gh/misaelzapata/fastfn)

!!! tip "Filosofía: El 'Next.js' para el Backend"
    **FastFN** te da la **Experiencia de Desarrollo de Next.js** pero para **Cualquier Lenguaje de Backend** (Python, Node, PHP, Lua, Go, Rust).
    
    Crea un archivo `api/users/[id].py`, y obtén un endpoint escalable `GET /api/users/:id` al instante. 
    Sin construir contenedores. Sin configurar YAML. **Solo código.**

Esta documentación sigue el framework **[Diátaxis](https://diataxis.fr/)** para que encuentres exactamente lo que necesitas según el momento.

<div class="grid cards" markdown>

-   **Tutoriales**
    
    Empieza aquí si eres nuevo. Lecciones paso a paso.
    
    [Comenzar aqui](./tutorial/primeros-pasos.md)

-   **Guias Como-Hacer**
    
    Recetas prácticas y accionables para tareas concretas.
    
    [Ver guias](./como-hacer/ejecutar-y-probar.md)

-   **Referencia**
    
    Descripciones técnicas de APIs, contratos y configuraciones.
    
    [Explorar referencia](./referencia/api-http.md)

-   **Explicacion**
    
    Profundización en arquitectura, decisiones de diseño y el "por qué".
    
    [Leer explicaciones](./explicacion/arquitectura.md)

</div>

## ¿Por qué FastFN?

### Mejor que FastApi/Express puro
*   **Cero Boilerplate**: Sin `app = FastAPI()`, sin `app.listen()`. Solo funciones.
*   **Auto-Discovery**: El sistema de archivos es el router.
*   **Políglota**: Mezcla Python para IA, Node para IO, Lua para glue logic y Rust para velocidad.

### Mejor que OpenFaaS/Knative
*   **Sin Kubernetes**: Corre en Docker simple o procesos nativos.
*   **Ciclo de Dev Instantáneo**: Los cambios se reflejan al instante (`fastfn dev`). Sin construir Docker por cambio.
*   **Ligero**: Mínimo consumo de recursos.

## Características clave

*   **Routing Mágico**: Soporte nativo para `[id]`, `[...slug]`.
*   **Gateway de bajo overhead**: OpenResty valida policy y despacha por unix sockets locales.
*   **Basado en estándares**: Generación automática OpenAPI 3.1.
*   **Developer first**: La plataforma se adapta a archivos de funciones.

*   **Multi-runtime**: Python, Node, PHP, Lua y Rust con un contrato uniforme.

## Enlaces rápidos

*   [Definición API HTTP](./referencia/api-http.md)
*   [Contrato del Runtime](./referencia/contrato-runtime.md)
*   [Funciones incluidas](./referencia/funciones-ejemplo.md)
*   [Recetas operativas](./como-hacer/recetas-operativas.md)
*   [Antes de salir a producción: checklist de seguridad](./como-hacer/checklist-seguridad-produccion.md)

## Tutoriales extendidos

*   [Construir una API completa (end-to-end)](./tutorial/construir-api-completa.md)
*   [Versionado y rollout](./tutorial/versionado-y-rollout.md)
*   [Auth y secretos](./tutorial/auth-y-secretos.md)

## Guías visuales

*   [Flujos visuales](./explicacion/flujos-visuales.md)
