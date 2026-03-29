# Parte 1: Setup y Primera Ruta

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.

## Vista rápida

- Complejidad: Principiante
- Tiempo típico: 15-20 minutos
- Resultado: proyecto limpio con endpoint `GET /tasks` y entrada en OpenAPI

## 1. Setup limpio

```bash
mkdir -p task-manager-api/functions/tasks
cd task-manager-api
```

## 2. Implementa la primera ruta (elige runtime)

=== "Node.js"
    Archivo: `functions/tasks/handler.js`

    ```js
    exports.handler = async () => ({
      status: 200,
      body: [
        { id: 1, title: "Aprender FastFN", completed: false },
        { id: 2, title: "Publicar primer endpoint", completed: false }
      ]
    });
    ```

=== "Python"
    Archivo: `functions/tasks/handler.py`

    ```python
    def handler(_event):
        return {
            "status": 200,
            "body": [
                {"id": 1, "title": "Aprender FastFN", "completed": False},
                {"id": 2, "title": "Publicar primer endpoint", "completed": False},
            ],
        }
    ```

=== "Rust"
    Archivo: `functions/tasks/handler.rs`

    ```rust
    use serde_json::json;

    pub fn handler(_event: serde_json::Value) -> serde_json::Value {
        json!({
            "status": 200,
            "body": [
                { "id": 1, "title": "Aprender FastFN", "completed": false },
                { "id": 2, "title": "Publicar primer endpoint", "completed": false }
            ]
        })
    }
    ```

=== "PHP"
    Archivo: `functions/tasks/handler.php`

    ```php
    <?php

    function handler(array $event): array {
        return [
            'status' => 200,
            'body' => [
                ['id' => 1, 'title' => 'Aprender FastFN', 'completed' => false],
                ['id' => 2, 'title' => 'Publicar primer endpoint', 'completed' => false],
            ],
        ];
    }
    ```

## 3. Ejecuta local

```bash
fastfn dev functions
```

## 4. Valida primera request (por runtime)

=== "Node.js"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks'
    ```

=== "Python"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks'
    ```

=== "Rust"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks'
    ```

=== "PHP"
    ```bash
    curl -sS 'http://127.0.0.1:8080/tasks'
    ```

Forma esperada:

```json
[
  { "id": 1, "title": "...", "completed": false },
  { "id": 2, "title": "...", "completed": false }
]
```

## 5. Valida visibilidad OpenAPI

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | jq '.paths | has("/tasks")'
```

Salida esperada:

```text
true
```

![Navegador mostrando la respuesta JSON en /tasks](../../../assets/screenshots/browser-json-tasks.png)

## Solución de problemas

- `503`: revisa `/_fn/health` y dependencias runtime
- ruta no encontrada: confirma handler en `functions/tasks/`
- OpenAPI sin path: ejecuta `curl -X POST http://127.0.0.1:8080/_fn/reload`

## Próximo paso

[Ir a la Parte 2: Enrutamiento y Datos](./2-enrutamiento-y-datos.md)

## Enlaces relacionados

- [Validación y schemas](../validacion-y-schemas.md)
- [Referencia API HTTP](../../referencia/api-http.md)
- [Ejecutar y probar](../../como-hacer/ejecutar-y-probar.md)
