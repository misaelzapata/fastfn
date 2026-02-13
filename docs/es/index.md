# Bienvenido a fastfn

!!! info "Filosofía"
    **fastfn** está diseñado para ser el camino más rápido desde código a endpoint HTTP: creas el handler y llamas `/fn/<nombre>`.

Esta documentación sigue el framework **[Diátaxis](https://diataxis.fr/)** para que encuentres exactamente lo que necesitas según el momento.

<div class="grid cards" markdown>

-   :material-school: **Tutoriales**
    
    Empieza aquí si eres nuevo. Lecciones paso a paso.
    
    [Comenzar Aquí :arrow_right:](./tutorial/primeros-pasos.md)

-   :material-compass-outline: **Guías Cómo-Hacer**
    
    Recetas prácticas y accionables para tareas concretas.
    
    [Ver Guías :arrow_right:](./como-hacer/ejecutar-y-probar.md)

-   :material-book-open-page-variant: **Referencia**
    
    Descripciones técnicas de APIs, contratos y configuraciones.
    
    [Explorar Referencia :arrow_right:](./referencia/api-http.md)

-   :material-text-box-search-outline: **Explicación**
    
    Profundización en arquitectura, decisiones de diseño y el "por qué".
    
    [Leer Explicaciones :arrow_right:](./explicacion/arquitectura.md)

</div>

## Características clave

*   **Gateway de bajo overhead**: OpenResty valida policy y despacha por unix sockets locales.
*   **Basado en estándares**: Generación automática OpenAPI 3.1.
*   **Developer first**: La plataforma se adapta a archivos de funciones.
*   **Multi-runtime**: Python, Node, PHP y Rust con un contrato uniforme.

## Enlaces rápidos

*   [Definición API HTTP](./referencia/api-http.md)
*   [Contrato del Runtime](./referencia/contrato-runtime.md)
*   [Funciones incluidas](./referencia/funciones-ejemplo.md)
*   [Recetas operativas](./como-hacer/recetas-operativas.md)

## Tutoriales extendidos

*   [Construir una API completa (end-to-end)](./tutorial/construir-api-completa.md)
*   [Versionado y rollout](./tutorial/versionado-y-rollout.md)
*   [Auth y secretos](./tutorial/auth-y-secretos.md)

## Guías visuales

*   [Flujos visuales](./explicacion/flujos-visuales.md)
