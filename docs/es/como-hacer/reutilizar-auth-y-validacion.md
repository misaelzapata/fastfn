# Reutilizar Auth y Validación entre Funciones

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.

## Vista rápida

- Complejidad: Intermedio
- Tiempo típico: 20-25 minutos
- Resultado: una cadena reusable de auth/validación aplicada en múltiples rutas

## Objetivo

Implementar un flujo reusable equivalente a "advanced dependencies":

1. Autenticar request
2. Autorizar permisos/scopes
3. Validar input
4. Ejecutar lógica de ruta

## Prerrequisitos

- Proyecto FastFN con raíz `functions/`
- Secreto `API_KEY` o token configurado en env de función
- `curl` instalado

## 1. Crear helpers compartidos

Estructura neutral:

```text
functions/
  _shared/
    auth.*
    validate.*
  reports/
    [id]/
      get.*
```

## 2. Ejemplos por runtime (tabs)

=== "Node.js"
    ```js
    // functions/reports/[id]/get.js
    const { requireApiKey, requireScope } = require("../../_shared/auth");
    const { requireId } = require("../../_shared/validate");

    exports.handler = async (event, params) => {
      const auth = requireApiKey(event);
      if (!auth.ok) return { status: auth.status, body: { error: auth.error } };
      const scope = requireScope(event, "reports:read");
      if (!scope.ok) return { status: scope.status, body: { error: scope.error } };
      const valid = requireId(params.id);
      if (!valid.ok) return { status: 422, body: { error: valid.error } };
      return { status: 200, body: { id: params.id, source: "reports" } };
    };
    ```

=== "Python"
    ```python
    # functions/reports/[id]/get.py
    from _shared.auth import require_api_key, require_scope
    from _shared.validate import require_id

    def handler(event, params):
        auth = require_api_key(event)
        if not auth["ok"]:
            return {"status": auth["status"], "body": {"error": auth["error"]}}
        scope = require_scope(event, "reports:read")
        if not scope["ok"]:
            return {"status": scope["status"], "body": {"error": scope["error"]}}
        valid = require_id(params.get("id"))
        if not valid["ok"]:
            return {"status": 422, "body": {"error": valid["error"]}}
        return {"status": 200, "body": {"id": params.get("id"), "source": "reports"}}
    ```

=== "Rust"
    ```rust
    use serde_json::{json, Value};
    use crate::shared::{require_api_key, require_scope, require_id};

    pub fn handler(event: Value, params: Value) -> Value {
        let auth = require_api_key(&event);
        if !auth["ok"].as_bool().unwrap_or(false) {
            return json!({"status": auth["status"], "body": {"error": auth["error"]}});
        }
        let scope = require_scope(&event, "reports:read");
        if !scope["ok"].as_bool().unwrap_or(false) {
            return json!({"status": scope["status"], "body": {"error": scope["error"]}});
        }
        let id = params.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let valid = require_id(id);
        if !valid["ok"].as_bool().unwrap_or(false) {
            return json!({"status": 422, "body": {"error": valid["error"]}});
        }
        json!({"status": 200, "body": {"id": id, "source": "reports"}})
    }
    ```

=== "PHP"
    ```php
    <?php
    require_once __DIR__ . '/../../_shared/auth.php';
    require_once __DIR__ . '/../../_shared/validate.php';

    function handler(array $event, array $params): array {
        $auth = require_api_key($event);
        if (!$auth['ok']) return ['status' => $auth['status'], 'body' => ['error' => $auth['error']]];
        $scope = require_scope($event, 'reports:read');
        if (!$scope['ok']) return ['status' => $scope['status'], 'body' => ['error' => $scope['error']]];
        $valid = require_id($params['id'] ?? '');
        if (!$valid['ok']) return ['status' => 422, 'body' => ['error' => $valid['error']]];
        return ['status' => 200, 'body' => ['id' => ($params['id'] ?? ''), 'source' => 'reports']];
    }
    ```

Notas de import por runtime:

- Python: agrega `functions/_shared/__init__.py` y mantiene `functions/` dentro del import path del runtime.
- Rust: expone helpers compartidos en el entry del crate (`mod shared;` en `lib.rs`/`main.rs`) antes de usar `crate::shared::*`.
- PHP: para rutas muy anidadas, conviene un bootstrap con constante de base path en lugar de acumular `../`.

## 3. Verificar con curl

```bash
curl -i 'http://127.0.0.1:8080/reports/1'
curl -i 'http://127.0.0.1:8080/reports/1' -H 'x-api-key: demo'
curl -i 'http://127.0.0.1:8080/reports/1' -H 'x-api-key: demo' -H 'x-scope: reports:read'
```

Resultado esperado:

- Sin API key: `401`
- Sin scope: `403`
- Id inválido: `422`
- Request válido: `200`

## Validación

- Cadena de guard ejecuta orden fijo (auth -> scope -> validación -> lógica).
- Al menos dos rutas reutilizan los mismos helpers.
- Errores consistentes entre runtimes.

## Troubleshooting

- Si falla parseo de scopes, normaliza separadores (`space`, `comma`) en helper.
- Si falla import en modo native, revisa working directory del runtime y paths relativos.
- Si diverge comportamiento entre runtimes, valida primero contrato de retorno de helpers.

## Enlaces relacionados

- [Patrones de lógica compartida](../explicacion/patrones-de-logica-compartida.md)
- [Auth y secretos](../tutorial/auth-y-secretos.md)
- [Checklist de seguridad](./checklist-seguridad-produccion.md)
