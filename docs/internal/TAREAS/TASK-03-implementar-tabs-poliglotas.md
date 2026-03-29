# TASK-03: Implementar Pestañas de Código (Tabs Políglotas)

**Status:** ✅ Done
**Encargado:** Codex (Agente)
**Revisión Cross:** Claude (Agente) ✅ — Revisión completada 2026-02-20. Defecto encontrado y corregido: tab PHP faltante en sección "Custom Headers and Redirects" de `4-advanced-responses.md`.

## Criterios de Revisión (Cross-Review)
El revisor (Claude) deberá verificar:
1. Que todos los bloques de código secuenciales en los tutoriales principales hayan sido convertidos a la sintaxis `=== "Lenguaje"`.
2. Que la indentación dentro de las pestañas sea exactamente de 4 espacios (requerimiento estricto de MkDocs).
3. Que el orden de las pestañas sea consistente en toda la documentación (ej. Python, Node.js, PHP, Rust).
4. Que no haya errores de renderizado en el sitio local (`mkdocs serve`) al visualizar las pestañas.

## Contexto del Proyecto
FastFN es un framework políglota (Python, Node, PHP, Rust). Actualmente, los tutoriales muestran ejemplos de código de forma secuencial (primero Python, luego Node, etc.). Esto obliga al usuario a hacer scroll por lenguajes que no le interesan, rompiendo la experiencia de lectura. El objetivo es usar la extensión `pymdownx.tabbed` de MkDocs para mostrar el código en pestañas interactivas.

## Archivos a Modificar
- `docs/en/tutorial/routing.md`
- `docs/en/how-to/zero-config-routing.md`
- `docs/en/tutorial/from-zero/*.md` (Todos los capítulos que tengan ejemplos en múltiples lenguajes)
- `docs/es/tutorial/routing.md` (y sus equivalentes en español)

## Instrucciones Detalladas
1. Busca en los archivos `.md` cualquier sección donde se muestre el mismo concepto en diferentes lenguajes (ej. "Python (`event`):" seguido de "Node (`event` o `context`):").
2. Reemplaza esos bloques secuenciales con la sintaxis de pestañas de MkDocs.
3. **Regla de Oro:** Mantén siempre el mismo orden en las pestañas a lo largo de toda la documentación para consistencia cognitiva (ej. Python, Node.js, PHP, Rust).
4. Asegúrate de que la indentación dentro de las pestañas sea exactamente de 4 espacios, como requiere MkDocs.

## Snippet de Código Exacto (Ejemplo de Reemplazo)

**Antes (Incorrecto):**
```markdown
**Python (`event`)**:
```python
def handler(event):
    user_id = event.get("params", {}).get("id")
    return {"status": 200, "body": user_id}
```

**Node (`event` o `context`)**:
```javascript
exports.handler = async (event) => {
    const userId = event.params.id;
    return { status: 200, body: userId };
};
```
```

**Después (Correcto - Usar esta sintaxis):**
```markdown
=== "Python"
    ```python
    def handler(event):
        # For /users/42, user_id will be "42"
        user_id = event.get("params", {}).get("id")
        return {"status": 200, "body": user_id}
    ```

=== "Node.js"
    ```javascript
    exports.handler = async (event) => {
        // For /users/42, userId will be "42"
        const userId = event.params.id;
        return { status: 200, body: userId };
    };
    ```

=== "PHP"
    ```php
    <?php
    return function($event) {
        $userId = $event['params']['id'] ?? null;
        return ["status" => 200, "body" => $userId];
    };
    ```
```
