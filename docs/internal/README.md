# Internal Documentation & Planning

Este directorio contiene la planificación interna, notas de migración y tickets de tareas para los mantenedores del proyecto FastFN.

## 🚀 Proyecto Activo: Modernización de Documentación (Estilo Next.js/FastAPI)

**Objetivo:** Elevar la experiencia de desarrollador (DX) de la documentación de FastFN al nivel de frameworks modernos como Next.js o FastAPI. La documentación actual es técnicamente correcta pero se lee como un manual interno. Necesitamos que sea empática, visual, orientada al viaje del usuario y que muestre la "magia" del framework (como el Swagger UI automático y el enrutamiento políglota) desde el primer minuto. **No se debe alterar el diseño CSS (`extra.css`) ni el logo.**

Los tickets detallados para los agentes/desarrolladores que ejecutarán este proyecto se encuentran en la carpeta `TAREAS/`. Cada ticket contiene contexto completo para ser ejecutado de forma independiente por cualquier agente sin conocimiento previo.

### Tickets de Ejecución (Orden Sugerido)
1. [TASK-01: Reestructurar la Navegación (mkdocs.yml)](./TAREAS/TASK-01-reestructurar-navegacion.md)
2. [TASK-02: Reescribir "First Steps" y Cambiar el Tono](./TAREAS/TASK-02-reescribir-first-steps.md)
3. [TASK-03: Implementar Pestañas de Código (Tabs Políglotas)](./TAREAS/TASK-03-implementar-tabs-poliglotas.md)
4. [TASK-04: Mejorar Ayudas Visuales y Formato](./TAREAS/TASK-04-mejorar-ayudas-visuales.md)
5. [TASK-05: Consolidar el Tutorial "From Zero"](./TAREAS/TASK-05-consolidar-tutorial-from-zero.md)

---

## 🗄️ Archivo Histórico (Notas Antiguas)

Los siguientes documentos son notas de planificación previas y volcados de contexto. No son necesarios para el usuario final.

- `TASK_QUEUE.md`: implementation queue/status used by maintainers.
- `CHANGELOG.md`: internal change log with revision IDs and target release notes.
- `MULTI_WORKERS_ANALYSIS.md`: architecture/effort analysis for multi-worker scaling.
- `CLOUDFLARE_WORKERS_PARITY_SPEC.md`: detailed parity gaps/spec between Cloudflare Workers docs model and FastFN.
- `chat_dump_openresty_faas.md`: archived conversation/context dump.
- `prefork-plan.md`: future scaling notes (not part of current implementation).
