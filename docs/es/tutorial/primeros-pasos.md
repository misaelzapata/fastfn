# Inicio Rápido

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.

## Vista rápida

- Complejidad: Principiante
- Tiempo típico: 10-15 minutos
- Alcance: crear una función, levantar local, llamar endpoint y validar OpenAPI
- Resultado esperado: endpoint `GET /hello` funcionando y docs en `/docs`

## Prerrequisitos

- CLI de FastFN instalado y disponible en `PATH`
- Un modo de ejecución listo:
  - Modo portable: Docker daemon activo
  - Modo native: `openresty` y runtimes de host disponibles

## 1. Crea tu primera función (path neutral)

```bash
mkdir -p functions/hello
```

Elige una implementación runtime dentro de `functions/hello/`:

=== "Node.js"
    Archivo: `functions/hello/handler.js`

    ```js
    exports.handler = async (event) => ({
      status: 200,
      body: { hello: event.query?.name || "World", runtime: "node" }
    });
    ```

=== "Python"
    Archivo: `functions/hello/handler.py`

    ```python
    def handler(event):
        name = (event.get("query") or {}).get("name", "World")
        return {"status": 200, "body": {"hello": name, "runtime": "python"}}
    ```

=== "Rust"
    Archivo: `functions/hello/handler.rs`

    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let name = event
            .get("query")
            .and_then(|q| q.get("name"))
            .and_then(|n| n.as_str())
            .unwrap_or("World");

        json!({
            "status": 200,
            "body": {
                "hello": name,
                "runtime": "rust"
            }
        })
    }
    ```

=== "PHP"
    Archivo: `functions/hello/handler.php`

    ```php
    <?php

    function handler(array $event): array {
        $query = $event['query'] ?? [];
        $name = $query['name'] ?? 'World';

        return [
            'status' => 200,
            'body' => [
                'hello' => $name,
                'runtime' => 'php',
            ],
        ];
    }
    ```

## 2. Inicia el servidor local

```bash
fastfn dev functions
```

## 3. Valida con curl (por runtime)

=== "Node.js"
    ```bash
    curl -sS 'http://127.0.0.1:8080/hello?name=World'
    ```

=== "Python"
    ```bash
    curl -sS 'http://127.0.0.1:8080/hello?name=World'
    ```

=== "Rust"
    ```bash
    curl -sS 'http://127.0.0.1:8080/hello?name=World'
    ```

=== "PHP"
    ```bash
    curl -sS 'http://127.0.0.1:8080/hello?name=World'
    ```

Forma esperada de respuesta:

```json
{
  "hello": "World",
  "runtime": "<runtime-seleccionado>"
}
```

## 4. Valida documentación generada

- Swagger UI: [http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs)
- OpenAPI JSON: [http://127.0.0.1:8080/openapi.json](http://127.0.0.1:8080/openapi.json)

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | jq '.paths | has("/hello")'
```

Salida esperada:

```text
true
```

![Swagger UI mostrando rutas de FastFN](../../assets/screenshots/swagger-ui.png)

## Checklist de validación

- `GET /hello` devuelve HTTP `200`
- `/openapi.json` contiene `/hello`
- `/docs` carga y muestra la ruta

## Solución de problemas

- Runtime caído o `503`: revisa `/_fn/health` y dependencias de host faltantes
- Ruta faltante: confirma layout y relanza discovery (`/_fn/reload`)
- `/docs` vacío: valida que no se desactivaron toggles de docs/OpenAPI

## Siguientes links

- [Parte 1: setup y primera ruta](./desde-cero/1-setup-y-primera-ruta.md)
- [Enrutamiento y parámetros](./routing.md)
- [Referencia API HTTP](../referencia/api-http.md)
