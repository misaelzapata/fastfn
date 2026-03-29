# Concurrencia y Async

> Estado verificado al **13 de marzo de 2026**.

## Vista rapida

- Complejidad: Intermedio
- Tiempo tipico: 10-15 minutos
- Resultado: modelo mental practico de concurrencia por runtime

## Modelo por runtime

| Runtime | Modelo | Nota practica |
|---|---|---|
| Node.js | event loop + async IO | evitar CPU blocking en request path |
| Python | proceso + workers | usar libs async para IO intensivo |
| Rust | handler compilado con async explicito | acotar serializacion e IO |
| PHP | daemon persistente con ciclos de invocacion | minimizar bootstrap por request |
| Go | goroutines + primitivas de concurrencia | explicitar estado compartido y evitar race conditions |
| Lua | runtime liviano en flujo OpenResty | mantener handlers cortos y conscientes de IO |

## Que optimizar primero

1. latencia de IO externo (DB/APIs)
2. tamano de payload + costo de serializacion
3. timeouts y reintentos acotados

## Validacion

- p95 estable bajo concurrencia esperada
- timeouts explicitos y testeados
- retries bounded + idempotentes

## Troubleshooting

- si cae p95, perfilar IO antes de CPU
- si suben timeouts, revisar rate limits downstream/pool sizing

## Enlaces relacionados

- [Benchmarks de rendimiento](./benchmarks-rendimiento.md)
- [Ejecutar y probar](../como-hacer/ejecutar-y-probar.md)
- [Plomeria runtime-plataforma](../como-hacer/plomeria-runtime-plataforma.md)
