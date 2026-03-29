# Auth Práctica para Funciones: API Keys, Firmas, Console Guard y Defaults Seguros


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
## Por qué importa este artículo
La seguridad suele llegar tarde y se implementa con más complejidad de la necesaria.

Esta guía propone una base práctica para producción:
- auth por función,
- límites estrictos de método y tamaño,
- consola protegida,
- patrón de validación de firma para webhooks.

## Mapa rápido de documentación
- Lista completa de endpoints: [API HTTP](../referencia/api-http.md)
- Claves de configuración de función: [Especificación de funciones](../referencia/especificacion-funciones.md)
- Modelo de acceso a consola: [Consola y administración](../como-hacer/consola-admin.md)
- Hardening operativo: [Recetas operativas](../como-hacer/recetas-operativas.md)
- Fundamentos de seguridad: [Modelo de seguridad](../explicacion/modelo-seguridad.md)

## Capas de seguridad en fastfn
1. Política del gateway en `fn.config.json`.
2. Lógica auth dentro del handler.
3. Gate de acceso para consola/UI.

En la práctica necesitás las tres.

## Capa 1: Bloquear política de gateway primero
Ejemplo mínimo seguro de `fn.config.json`:

```json
{
  "timeout_ms": 1500,
  "max_concurrency": 5,
  "max_body_bytes": 131072,
  "invoke": {
    "methods": ["POST"],
    "summary": "Webhook firmado"
  }
}
```

Efectos:
- método distinto de POST falla con `405`,
- body gigante falla con `413`,
- exceso de paralelismo falla con `429`.

## Capa 2: API key auth dentro de la función
Ejemplo Node:

```js
exports.handler = async (event) => {
  const headers = event.headers || {};
  const apiKey = headers['x-api-key'] || headers['X-API-Key'];
  const expected = (event.env || {}).MY_API_KEY;

  if (!expected || apiKey !== expected) {
    return {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ error: 'unauthorized' })
    };
  }

  return {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ok: true })
  };
};
```

Guardar secreto en `fn.env.json`:

```json
{
  "MY_API_KEY": { "value": "set-me", "is_secret": true }
}
```

## Capa 3: Firma para webhooks externos
Para integraciones tipo Stripe/GitHub, validar firma sobre body crudo.

Patrón:
1. leer body crudo desde `event.body`,
2. calcular HMAC con secreto,
3. comparar contra header de firma,
4. rechazar con `401` si no coincide.

Es más robusto que API key fija para callbacks externos.

## Capa 4: Proteger consola y APIs admin
Variables recomendadas:

```bash
FN_UI_ENABLED=1
FN_CONSOLE_LOCAL_ONLY=1
FN_CONSOLE_WRITE_ENABLED=0
FN_ADMIN_TOKEN=<token-aleatorio-fuerte>
```

Significado:
- UI habilitada,
- acceso local por default,
- escrituras deshabilitadas salvo token admin.

## Checklist de verificación
1. Sin API key devuelve `401`.
2. Método inválido devuelve `405`.
3. Payload grande devuelve `413`.
4. Firma inválida devuelve `401`.
5. Escritura en consola sin auth devuelve `403`.

## Curls de prueba rápida
Sin auth:

```bash
curl -i -sS -X POST http://127.0.0.1:8080/secure-webhook
```

Método inválido:

```bash
curl -i -sS http://127.0.0.1:8080/secure-webhook
```

Esperado: códigos `401` y `405` respectivamente.

## Errores frecuentes
- secretos en código en vez de `fn.env.json`,
- consola con escrituras expuesta a red remota,
- endpoints sensibles permitiendo `GET`,
- sin límite de body en webhooks.

## Perfil recomendado de base
Para endpoints externos:
- métodos mínimos necesarios,
- límite de body bajo (menos de 256 KB salvo excepción),
- concurrencia baja para integraciones costosas,
- consola local-only con token para acciones privilegiadas.

## Documentación relacionada
- [API HTTP](../referencia/api-http.md)
- [Especificación de funciones](../referencia/especificacion-funciones.md)
- [Consola y administración](../como-hacer/consola-admin.md)
- [Recetas operativas](../como-hacer/recetas-operativas.md)
- [Modelo de seguridad](../explicacion/modelo-seguridad.md)

## Idea clave

Empezá con límites en el gateway y agregá autenticación dentro del handler solo donde la identidad realmente importe. Esa combinación corta requests malos antes y deja un código de auth corto, revisable y fácil de testear.

## Qué conviene tener en cuenta

- Guardá secretos en `fn.env.json`, no en el código ni en payloads de ejemplo.
- Restringí métodos y tamaño de body antes de que la request llegue al handler.
- Tratá rutas públicas y endpoints de consola/admin como superficies de seguridad distintas.

## Qué patrón conviene según el caso

- API keys funcionan bien para tráfico entre servicios y webhooks privados.
- Verificación de firmas conviene cuando el proveedor ya manda un header firmable.
- JWT encaja mejor cuando otro servicio se ocupa del login y de emitir el token.

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)

## Patron JWT: emision y verificacion

Arquitectura recomendada:

1. emitir JWT en servicio de auth dedicado
2. verificar firma + expiracion en helper FastFN
3. mapear claims (`sub`, `scope`, `aud`) a permisos locales

Ejemplo rapido:

```bash
curl -i 'http://127.0.0.1:8080/private' -H 'authorization: Bearer <jwt>'
```

Esperado:

- token invalido/expirado -> `401`
- scope insuficiente -> `403`
- token valido con scope -> `200`
