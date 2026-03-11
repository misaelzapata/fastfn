# Flujo de invocación


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
## Flujo público (`/<name>`)

1. La petición entra al gateway Lua.
2. Se resuelve runtime/versión por discovery.
3. Se validan método, body, concurrencia y timeout.
4. Se construye `event`.
5. Se envía JSON enmarcado al runtime por socket Unix.
6. El runtime ejecuta el handler.
7. El gateway devuelve la respuesta HTTP final.

## Flujo interno `/_fn/invoke`

`/_fn/invoke` no llama runtimes directamente.

Construye una request interna y la enruta por la misma capa de routing/política que el tráfico público.
Eso garantiza consistencia en métodos, límites, errores y formato de respuesta.

## Context

Si `/_fn/invoke` recibe `context`, lo serializa y lo envía al gateway, que lo expone en `event.context.user` para el handler.

## Problema

Qué dolor operativo o de DX resuelve este tema.

## Modelo Mental

Cómo razonar esta feature en entornos similares a producción.

## Decisiones de Diseño

- Por qué existe este comportamiento
- Qué tradeoffs se aceptan
- Cuándo conviene una alternativa

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
