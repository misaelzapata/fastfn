# Inyección Directa de Parámetros de Ruta


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
FastFN inyecta automáticamente los parámetros de ruta como **argumentos directos de la función**. En vez de extraer `event.params.id` manualmente, solo declara `id` en la firma del handler y llega listo para usar.

## Antes y Después

**Antes** (extracción manual):
```python
def handler(event):
    id = event.get("params", {}).get("id", "")
    slug = event.get("params", {}).get("slug", "")
```

**Después** (inyección directa):
```python
def handler(event, id, slug):
    # id y slug llegan directamente!
```

## Cómo Funciona

FastFN inspecciona la firma del handler al momento de llamarlo e inyecta los parámetros de ruta automáticamente.

| Runtime | Mecanismo | Firma del Handler |
|---------|-----------|-------------------|
| Python | `inspect.signature` → kwargs | `def handler(event, id):` |
| Node.js | Segundo arg cuando `handler.length > 1` | `async (event, { id }) =>` |
| PHP | `ReflectionFunction` → segundo arg | `function handler($event, $params)` |
| Lua | Siempre pasa segundo arg | `function handler(event, params)` |
| Go | Params fusionados en event map | `event["id"].(string)` |
| Rust | Params fusionados en event value | `event["id"].as_str()` |

!!! tip "100% Compatible con Código Existente"
    Las firmas `handler(event)` existentes siguen funcionando sin cambios. Los params solo se inyectan cuando el handler declara parámetros extra.

---

## Tipos de Parámetros

### `[id]` — Parámetro Dinámico Simple

Archivo: `products/[id]/get.py` → Ruta: `GET /products/:id`

=== "Python"
    ```python
    def handler(event, id):
        return {"status": 200, "body": {"id": int(id), "name": "Widget"}}
    ```

=== "Node.js"
    ```javascript
    exports.handler = async (event, { id }) => ({
      status: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: Number(id), name: "Widget" }),
    });
    ```

=== "PHP"
    ```php
    <?php
    function handler($event, $params) {
        $id = $params["id"] ?? "";
        return [
            "status" => 200,
            "headers" => ["Content-Type" => "application/json"],
            "body" => json_encode(["id" => (int)$id, "name" => "Widget"]),
        ];
    }
    ```

=== "Lua"
    ```lua
    local cjson = require("cjson")

    local function handler(event, params)
        local id = params.id or ""
        return {
            status = 200,
            headers = { ["Content-Type"] = "application/json" },
            body = cjson.encode({ id = tonumber(id), name = "Widget" }),
        }
    end

    return handler
    ```

=== "Go"
    ```go
    package main

    import ("encoding/json"; "strconv")

    func handler(event map[string]interface{}) interface{} {
        idStr, _ := event["id"].(string)  // fusionado desde params
        id, _ := strconv.Atoi(idStr)
        body, _ := json.Marshal(map[string]interface{}{"id": id, "name": "Widget"})
        return map[string]interface{}{
            "status": 200, "headers": map[string]string{"Content-Type": "application/json"},
            "body": string(body),
        }
    }
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let id: i64 = event["id"].as_str().unwrap_or("0").parse().unwrap_or(0);
        json!({
            "status": 200,
            "headers": { "Content-Type": "application/json" },
            "body": serde_json::to_string(&json!({"id": id, "name": "Widget"})).unwrap()
        })
    }
    ```

### `[slug]` — Parámetro Nombrado

Archivo: `posts/[slug]/get.py` → Ruta: `GET /posts/:slug`

=== "Python"
    ```python
    def handler(event, slug):
        return {"status": 200, "body": {"slug": slug, "title": f"Post: {slug}"}}
    ```

=== "Node.js"
    ```javascript
    exports.handler = async (event, { slug }) => ({
      status: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ slug, title: `Post: ${slug}` }),
    });
    ```

### `[category]/[slug]` — Múltiples Parámetros

Archivo: `posts/[category]/[slug]/get.py` → Ruta: `GET /posts/:category/:slug`

=== "Python"
    ```python
    def handler(event, category, slug):
        return {
            "status": 200,
            "body": {"category": category, "slug": slug, "url": f"/posts/{category}/{slug}"},
        }
    ```

=== "Node.js"
    ```javascript
    exports.handler = async (event, { category, slug }) => ({
      status: 200,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ category, slug, url: `/posts/${category}/${slug}` }),
    });
    ```

### `[...path]` — Wildcard Catch-All

Archivo: `files/[...path]/get.py` → Ruta: `GET /files/*`

Todo el path restante después de `/files/` se captura como un solo string.

=== "Python"
    ```python
    def handler(event, path):
        # /files/docs/2024/report.pdf -> path = "docs/2024/report.pdf"
        segments = path.split("/") if path else []
        return {
            "status": 200,
            "body": {"path": path, "segments": segments, "depth": len(segments)},
        }
    ```

=== "Node.js"
    ```javascript
    exports.handler = async (event, { path }) => {
      const segments = path ? path.split("/") : [];
      return {
        status: 200,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ path, segments, depth: segments.length }),
      };
    };
    ```

---

## Ejemplo CRUD Completo

API REST completa usando archivos por método con inyección de params:

```text
products/
  get.py          GET    /products        — listar todos
  post.py         POST   /products        — crear
  [id]/
    get.py        GET    /products/:id    — leer uno
    put.py        PUT    /products/:id    — actualizar
    delete.py     DELETE /products/:id    — eliminar
```

Cada handler es limpio y enfocado:

```python
# products/get.py — listar todos
def handler(event):
    return {"status": 200, "body": [{"id": 1, "name": "Widget"}]}

# products/post.py — crear
def handler(event):
    import json
    body = json.loads(event.get("body", "{}"))
    return {"status": 201, "body": {"id": 1, "name": body.get("name")}}

# products/[id]/get.py — leer uno
def handler(event, id):
    return {"status": 200, "body": {"id": int(id), "name": "Widget"}}

# products/[id]/put.py — actualizar
def handler(event, id):
    import json
    body = json.loads(event.get("body", "{}"))
    return {"status": 200, "body": {"id": int(id), "name": body.get("name")}}

# products/[id]/delete.py — eliminar
def handler(event, id):
    return {"status": 200, "body": {"id": int(id), "deleted": True}}
```

## Probar con curl

```bash
fastfn dev examples/functions/rest-api-methods

# Listar
curl http://127.0.0.1:8080/products

# Crear
curl -X POST http://127.0.0.1:8080/products \
  -H "Content-Type: application/json" -d '{"name":"Widget"}'

# Leer (id=42 inyectado directamente)
curl http://127.0.0.1:8080/products/42

# Actualizar
curl -X PUT http://127.0.0.1:8080/products/42 \
  -H "Content-Type: application/json" -d '{"name":"Actualizado"}'

# Eliminar
curl -X DELETE http://127.0.0.1:8080/products/42

# Parámetro slug
curl http://127.0.0.1:8080/posts/hola-mundo

# Multi-parámetro
curl http://127.0.0.1:8080/posts/tech/hola-mundo

# Wildcard catch-all
curl http://127.0.0.1:8080/files/docs/2024/reporte.pdf
```

## Resumen

| Patrón | Archivo | Python | Node.js |
|--------|---------|--------|---------|
| `[id]` | `[id]/get.py` | `def handler(event, id):` | `async (event, { id }) =>` |
| `[slug]` | `[slug]/get.py` | `def handler(event, slug):` | `async (event, { slug }) =>` |
| Multi | `[cat]/[slug]/get.py` | `def handler(event, category, slug):` | `async (event, { category, slug }) =>` |
| Catch-all | `[...path]/get.py` | `def handler(event, path):` | `async (event, { path }) =>` |

Consulta los ejemplos completos en `examples/functions/rest-api-methods/`.

## Diagrama de Flujo

```mermaid
flowchart LR
  A["Request del cliente"] --> B["Discovery de rutas"]
  B --> C["Validación de políticas y método"]
  C --> D["Ejecución del handler runtime"]
  D --> E["Respuesta HTTP + paridad OpenAPI"]
```

## Objetivo

Alcance claro, resultado esperado y público al que aplica esta guía.

## Prerrequisitos

- CLI de FastFN disponible
- Dependencias por modo verificadas (Docker para `fastfn dev`, OpenResty+runtimes para `fastfn dev --native`)

## Checklist de Validación

- Los comandos de ejemplo devuelven estados esperados
- Las rutas aparecen en OpenAPI cuando aplica
- Las referencias del final son navegables

## Solución de Problemas

- Si un runtime cae, valida dependencias de host y endpoint de health
- Si faltan rutas, vuelve a ejecutar discovery y revisa layout de carpetas

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
