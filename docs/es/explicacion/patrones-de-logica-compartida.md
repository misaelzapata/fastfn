# Patrones de Lógica Compartida (Equivalente a Dependencias)

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.

## Vista rápida

- Complejidad: Intermedio
- Tiempo típico: 15-20 minutos
- Resultado: lógica reutilizable por request sin dependency injection por decoradores

FastFN no usa dependency injection por decoradores. El equivalente es composición explícita con helpers/módulos compartidos entre funciones.

## 1. Patrón base: helper puro + handler

Estructura neutral recomendada:

```text
functions/
  _shared/
    auth.*
    validate.*
  profile/
    get.*
```

En cada runtime, importa lógica compartida antes del código de negocio.

=== "Node.js"
    ```js
    // functions/_shared/auth.js
    exports.requireApiKey = (event) => {
      const key = event.headers?.["x-api-key"];
      if (key !== event.env?.API_KEY) return { ok: false, status: 401, error: "unauthorized" };
      return { ok: true };
    };
    ```

=== "Python"
    ```python
    # functions/_shared/auth.py
    def require_api_key(event):
        key = (event.get("headers") or {}).get("x-api-key")
        if key != (event.get("env") or {}).get("API_KEY"):
            return {"ok": False, "status": 401, "error": "unauthorized"}
        return {"ok": True}
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn require_api_key(event: &Value) -> Value {
        let key = event["headers"]["x-api-key"].as_str().unwrap_or("");
        let expected = event["env"]["API_KEY"].as_str().unwrap_or("");
        if key != expected {
            return json!({"ok": false, "status": 401, "error": "unauthorized"});
        }
        json!({"ok": true})
    }
    ```

=== "PHP"
    ```php
    <?php
    function require_api_key(array $event): array {
        $headers = $event['headers'] ?? [];
        $env = $event['env'] ?? [];
        if (($headers['x-api-key'] ?? null) !== ($env['API_KEY'] ?? null)) {
            return ['ok' => false, 'status' => 401, 'error' => 'unauthorized'];
        }
        return ['ok' => true];
    }
    ```

## 2. Reuso por clase/módulo

Si el equipo prefiere encapsular por clase:

- Crea servicio con config desde `event.env`.
- Llama métodos del servicio desde handler.
- Mantén efectos secundarios en borde del handler.

Esto cubre el caso FastAPI "classes as dependencies" con módulos nativos por lenguaje.

## 3. Cadenas composables (equivalente sub-dependencies)

Compón helpers en secuencia:

1. Parsear identidad
2. Autorizar rol/scope
3. Validar payload
4. Ejecutar lógica de negocio

Flujo corto agnóstico de runtime:

```text
request -> parse_user -> require_scope -> validate_input -> handler_logic -> response
```

## Validación

- Helpers compartidos usados por al menos dos funciones.
- Request no autorizado responde `401` desde el guard.
- Helper de validación devuelve `422` determinístico.

## Troubleshooting

- Si falla import, revisa paths relativos desde el archivo de función.
- Si diverge comportamiento entre runtimes, unifica envelope (`ok`, `status`, `error`).
- Si hay tests inestables, separa helpers de red y reloj.

## Enlaces relacionados

- [Reutilizar auth y validación](../como-hacer/reutilizar-auth-y-validacion.md)
- [Auth y secretos](../tutorial/auth-y-secretos.md)
- [Ejecutar y probar](../como-hacer/ejecutar-y-probar.md)
