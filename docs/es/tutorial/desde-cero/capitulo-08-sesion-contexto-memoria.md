# Capitulo 8 - Contexto (Auth + Trace IDs) y Memoria Basica

**Objetivo**: leer metadata desde `event.context` sin mezclarla con tu JSON body.

FastFN extrae un subset seguro de headers y los mapea a `event.context.user`.

## 1) Crea un endpoint `whoami`

Crea `functions/whoami/get.js`:

```js
exports.handler = async (event) => {
  const ctx = event.context || {};
  const user = ctx.user || { id: "anonymous" };

  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      ok: true,
      request_id: event.id,
      user,
    }),
  };
};
```

## 2) Envia headers de usuario

```bash
curl -sS \
  -H 'x-user-id: 123' \
  -H 'x-role: admin' \
  http://127.0.0.1:8080/whoami
```

Forma esperada:

```json
{"ok":true,"request_id":"...","user":{"id":"123","role":"admin"}}
```

## 3) Invocacion interna (avanzado)

FastFN tambien expone `POST /_fn/invoke` para tooling interno. Permite inyectar un `context` completo (incluyendo `context.user`) para tests/scheduler/control-plane.

No se recomienda exponerlo como endpoint publico.

## 4) Memoria basica (patron)

Patron simple para bots o sesiones:

- clave estable por usuario: `chat_id`, `user_id`, session id
- guarda ultimos N turnos
- TTL configurable

Ejemplo real: `telegram-ai-reply`.

