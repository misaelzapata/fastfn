# Parte 2: Enrutamiento y Datos

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.

## Vista rápida

- Complejidad: Intermedio
- Tiempo típico: 25-35 minutos
- Resultado: manejo dinámico de path/query/body con validaciones explícitas

## 1. Path params y catch-all

Crea rutas dinámicas bajo `functions/`.

=== "Node.js"
    Archivo: `functions/tasks/[id].js`

    ```js
    exports.handler = async (_event, { id }) => ({ status: 200, body: { task_id: id } });
    ```

    Archivo: `functions/reports/[...slug].js`

    ```js
    exports.handler = async (_event, { slug }) => ({ status: 200, body: { path: slug } });
    ```

=== "Python"
    Archivo: `functions/tasks/[id].py`

    ```python
    def handler(_event, params):
        return {"status": 200, "body": {"task_id": params.get("id")}}
    ```

=== "Rust"
    Archivo: `functions/tasks/[id].rs`

    ```rust
    use serde_json::{json, Value};

    pub fn handler(_event: Value, params: Value) -> Value {
        json!({"status": 200, "body": {"task_id": params.get("id").and_then(|v| v.as_str()).unwrap_or("")}})
    }
    ```

=== "PHP"
    Archivo: `functions/tasks/[id].php`

    ```php
    <?php
    function handler(array $event, array $params): array {
        return ['status' => 200, 'body' => ['task_id' => $params['id'] ?? '']];
    }
    ```

Curls de validación (iguales para todos los runtimes):

```bash
curl -sS 'http://127.0.0.1:8080/tasks/42'
curl -sS 'http://127.0.0.1:8080/reports/2026/03/daily'
```

## 2. Query params con defaults

=== "Node.js"
    Archivo: `functions/tasks/search.js`

    ```js
    exports.handler = async (event) => {
      const q = event.query?.q;
      const page = Number(event.query?.page || "1");
      if (!q) return { status: 400, body: { error: "q es requerido" } };
      return { status: 200, body: { q, page } };
    };
    ```

=== "Python"
    Archivo: `functions/tasks/search.py`

    ```python
    def handler(event):
        query = event.get("query") or {}
        q = query.get("q")
        page = int(query.get("page", "1"))
        if not q:
            return {"status": 400, "body": {"error": "q es requerido"}}
        return {"status": 200, "body": {"q": q, "page": page}}
    ```

=== "Rust"
    Archivo: `functions/tasks/search.rs`

    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let q = event.get("query").and_then(|x| x.get("q")).and_then(|x| x.as_str());
        if q.is_none() {
            return json!({"status": 400, "body": {"error": "q es requerido"}});
        }
        json!({"status": 200, "body": {"q": q.unwrap(), "page": 1}})
    }
    ```

=== "PHP"
    Archivo: `functions/tasks/search.php`

    ```php
    <?php
    function handler(array $event): array {
        $query = $event['query'] ?? [];
        $q = $query['q'] ?? null;
        $page = intval($query['page'] ?? '1');
        if (!$q) return ['status' => 400, 'body' => ['error' => 'q es requerido']];
        return ['status' => 200, 'body' => ['q' => $q, 'page' => $page]];
    }
    ```

Curls por runtime:

=== "Node.js"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/search?page=2'
    curl -sS 'http://127.0.0.1:8080/tasks/search?q=fastfn'
    ```

=== "Python"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/search?page=2'
    curl -sS 'http://127.0.0.1:8080/tasks/search?q=fastfn'
    ```

=== "Rust"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/search?page=2'
    curl -sS 'http://127.0.0.1:8080/tasks/search?q=fastfn'
    ```

=== "PHP"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks/search?page=2'
    curl -sS 'http://127.0.0.1:8080/tasks/search?q=fastfn'
    ```

## 3. Parseo JSON y validación de body

=== "Node.js"
    Archivo: `functions/tasks/post.js`

    ```js
    exports.handler = async (event) => {
      let payload;
      try { payload = JSON.parse(event.body || "{}"); }
      catch { return { status: 400, body: { error: "JSON body inválido" } }; }
      if (!payload.title || typeof payload.title !== "string") {
        return { status: 422, body: { error: "title debe ser string no vacío" } };
      }
      return { status: 201, body: { id: 3, title: payload.title } };
    };
    ```

=== "Python"
    Archivo: `functions/tasks/post.py`

    ```python
    import json

    def handler(event):
        try:
            payload = json.loads(event.get("body") or "{}")
        except Exception:
            return {"status": 400, "body": {"error": "JSON body inválido"}}
        if not payload.get("title"):
            return {"status": 422, "body": {"error": "title debe ser string no vacío"}}
        return {"status": 201, "body": {"id": 3, "title": payload["title"]}}
    ```

=== "Rust"
    Archivo: `functions/tasks/post.rs`

    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let payload = event.get("body").and_then(|b| b.as_str()).unwrap_or("{}");
        let parsed: Value = serde_json::from_str(payload).unwrap_or(json!({"_error": "invalid"}));
        if parsed.get("_error").is_some() {
            return json!({"status": 400, "body": {"error": "JSON body inválido"}});
        }
        if parsed.get("title").and_then(|x| x.as_str()).unwrap_or("").is_empty() {
            return json!({"status": 422, "body": {"error": "title debe ser string no vacío"}});
        }
        json!({"status": 201, "body": {"id": 3, "title": parsed["title"]}})
    }
    ```

=== "PHP"
    Archivo: `functions/tasks/post.php`

    ```php
    <?php
    function handler(array $event): array {
        $raw = $event['body'] ?? '{}';
        $payload = json_decode($raw, true);
        if (!is_array($payload)) return ['status' => 400, 'body' => ['error' => 'JSON body inválido']];
        if (empty($payload['title']) || !is_string($payload['title'])) {
            return ['status' => 422, 'body' => ['error' => 'title debe ser string no vacío']];
        }
        return ['status' => 201, 'body' => ['id' => 3, 'title' => $payload['title']]];
    }
    ```

Curls por runtime:

=== "Node.js"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{bad'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Escribir docs"}'
    ```

=== "Python"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{bad'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Escribir docs"}'
    ```

=== "Rust"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{bad'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Escribir docs"}'
    ```

=== "PHP"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{bad'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{}'
    curl -sS -X POST 'http://127.0.0.1:8080/tasks' -H 'Content-Type: application/json' -d '{"title":"Escribir docs"}'
    ```

## Diagrama de flujo

```mermaid
flowchart LR
  A["Path"] --> B["Extracción params"]
  B --> C["Parseo query"]
  C --> D["Parseo body"]
  D --> E["Validación"]
  E --> F["Respuesta HTTP"]
```

## Solución de problemas

- handler incorrecto: revisa prefijos de método y nombre de archivo
- params vacíos: confirma patrón `[id]` o `[...slug]`
- parseo body falla: revisa `Content-Type: application/json` y JSON válido

## Próximo paso

[Ir a la Parte 3: Configuración y Secretos](./3-configuracion-y-secretos.md)

## Enlaces relacionados

- [Validación y schemas](../validacion-y-schemas.md)
- [Metadata de request y archivos](../metadata-request-y-archivos.md)
- [Referencia API HTTP](../../referencia/api-http.md)
