# Seguridad para Funciones

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por funcion desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.

## Vista rapida

- Complejidad: Intermedio
- Tiempo tipico: 20-30 minutos
- Resultado: baseline de seguridad claro con resolucion de identidad y privilegio minimo

## Modelo de amenaza en FastFN

Limites de confianza por defecto:

1. limite publico (`/<ruta>`)
2. limite admin de plataforma (`/_fn/*`, `/console`)
3. limite de proceso runtime (daemon/worker por lenguaje)

Defaults recomendados:

- mantener `FN_CONSOLE_LOCAL_ONLY=1`
- mantener `FN_CONSOLE_WRITE_ENABLED=0` en entornos compartidos
- requerir `FN_ADMIN_TOKEN` para acciones admin remotas
- guardar secretos de negocio en env de funcion (`event.env`)

## Patron de resolucion de identidad

Resuelve identidad una vez y pasa un usuario normalizado a la logica.

=== "Node.js"
    ```js
    exports.handler = async (event) => {
      const auth = event.headers?.authorization || "";
      const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
      if (!token) return { status: 401, body: { error: "missing bearer token" } };
      const user = { id: "u-123", roles: ["reader"] };
      return { status: 200, body: { user } };
    };
    ```

=== "Python"
    ```python
    def handler(event):
        auth = (event.get("headers") or {}).get("authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        if not token:
            return {"status": 401, "body": {"error": "missing bearer token"}}
        user = {"id": "u-123", "roles": ["reader"]}
        return {"status": 200, "body": {"user": user}}
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};

    pub fn handler(event: Value) -> Value {
        let auth = event["headers"]["authorization"].as_str().unwrap_or("");
        let token = auth.strip_prefix("Bearer ").unwrap_or("");
        if token.is_empty() {
            return json!({"status": 401, "body": {"error": "missing bearer token"}});
        }
        json!({"status": 200, "body": {"user": {"id": "u-123", "roles": ["reader"]}}})
    }
    ```

=== "PHP"
    ```php
    <?php
    function handler(array $event): array {
        $headers = $event['headers'] ?? [];
        $auth = $headers['authorization'] ?? '';
        $token = str_starts_with($auth, 'Bearer ') ? substr($auth, 7) : '';
        if ($token === '') return ['status' => 401, 'body' => ['error' => 'missing bearer token']];
        return ['status' => 200, 'body' => ['user' => ['id' => 'u-123', 'roles' => ['reader']]]];
    }
    ```

=== "Go"
    ```go
    package main

    import "strings"

    func Handler(event map[string]any) map[string]any {
      headers, _ := event["headers"].(map[string]any)
      auth, _ := headers["authorization"].(string)
      token := strings.TrimPrefix(auth, "Bearer ")
      if token == "" {
        return map[string]any{"status": 401, "body": map[string]any{"error": "missing bearer token"}}
      }
      return map[string]any{"status": 200, "body": map[string]any{"user": map[string]any{"id": "u-123", "roles": []string{"reader"}}}}
    }
    ```

=== "Lua"
    ```lua
    local cjson = require("cjson.safe")

    function handler(event)
      local headers = event.headers or {}
      local auth = headers.authorization or headers.Authorization or ""
      local token = auth:match("^Bearer%s+(.+)") or ""
      if token == "" then
        return { status = 401, body = cjson.encode({ error = "missing bearer token" }) }
      end
      return { status = 200, body = cjson.encode({ user = { id = "u-123", roles = { "reader" } } }) }
    end
    ```

## Validacion

```bash
curl -i 'http://127.0.0.1:8080/profile/me'
curl -i 'http://127.0.0.1:8080/profile/me' -H 'authorization: Bearer demo-token'
```

Nota: los snippets muestran el patron de flujo auth (extraccion de token + gate). La verificacion de firma/expiracion se implementa con tu libreria/proveedor de tokens.

Esperado:

- sin token: `401`
- con token: `200`

## Troubleshooting

- Si todo devuelve `401`, confirma la clave de header que recibe tu runtime (`authorization` vs `Authorization`).
- Si endpoints admin quedan expuestos remoto, verifica `FN_CONSOLE_LOCAL_ONLY` y firewall.
- Si faltan secretos, revisa registro de env por funcion y recarga runtime.

## Enlaces relacionados

- [Autenticacion y control de acceso](../como-hacer/autenticacion.md)
- [Checklist de seguridad](../como-hacer/checklist-seguridad-produccion.md)
- [Contrato runtime](../referencia/contrato-runtime.md)
