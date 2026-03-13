# Matriz de Soporte: Protocolos Avanzados

> Estado verificado al **13 de marzo de 2026**.

## Vista rapida

- Complejidad: Intermedio
- Tiempo tipico: 10 minutos
- Resultado: postura de soporte clara (`supported`, `adjacent-stack`, `out-of-scope`)

## Postura de soporte

| Capacidad | Postura | Por que | Camino recomendado |
|---|---|---|---|
| Proxy sub-apps | adjacent-stack | depende de topologia gateway upstream | usar API gateway/reverse proxy dedicado |
| Archivos estaticos | adjacent-stack | CDN/object storage lo resuelven mejor | servir estatico desde CDN |
| Templates server-side | adjacent-stack | runtime/state concerns especificos | pre-render o web tier dedicado |
| GraphQL server | adjacent-stack | requiere lifecycle y schema dedicado | servicio GraphQL separado |
| WebSockets | out-of-scope (core) | conexion larga no encaja con FaaS request/response | realtime dedicado + callbacks HTTP |

## Guia de decision

- usa FastFN para workloads HTTP de vida corta
- combina con componentes especializados para conexiones persistentes
- mantener contratos API estables entre componentes

## Validacion

- arquitectura documenta que corre en FastFN vs stack adyacente
- limites y workaround quedan explicitos

## Troubleshooting

- si necesitas websocket-like, usar polling/SSE o infra realtime
- si estatico/template esta lento, mover render a CDN/cache de borde

## Enlaces relacionados

- [Arquitectura](./arquitectura.md)
- [Comparacion tecnica](./comparacion.md)
- [Desplegar a produccion](../como-hacer/desplegar-a-produccion.md)
