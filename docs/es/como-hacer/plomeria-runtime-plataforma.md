# Plomeria Runtime-Plataforma

> Estado verificado al **13 de marzo de 2026**.

## Vista rapida

- Complejidad: Avanzado
- Tiempo tipico: 25-35 minutos
- Resultado: pipeline de request predecible (hooks tipo middleware, CORS, acceso raw, eventos)

## Limites del pipeline

Flujo base:

1. resolucion de ruta
2. validaciones/guards
3. dispatch a runtime
4. normalizacion de respuesta

## Matriz CORS

| Escenario | Origin | Metodos | Headers | Credenciales | Resultado |
|---|---|---|---|---|---|
| API publica lectura | dominios especificos | `GET` | minimos | no | default seguro |
| Backend dashboard | dominio confiable | `GET,POST,PUT,DELETE` | auth | si | allowlist estricto |
| Herramienta interna | red privada | segun necesidad | explicitos | opcional | restringir por red |

```bash
curl -i 'http://127.0.0.1:8080/items' \
  -H 'Origin: https://app.example.com' \
  -H 'Access-Control-Request-Method: POST'
```

## Uso de request raw

Campos utiles:

- `event.method`
- `event.headers`
- `event.query`
- `event.path`
- `event.body`

Ideal para firmas/webhooks y adaptaciones de bajo nivel.

## Eventos y timing

Eventos operativos:

- startup (OpenResty + daemons runtime)
- health check (`/_fn/health`)
- shutdown/restart
- crash de runtime + recuperacion

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health'
```

## Validacion

- preflight y request simple CORS consistentes
- guards bloquean antes de ejecutar logica
- health refleja estado real runtime

## Troubleshooting

- si falla CORS, confirma `Origin` exacto y headers de respuesta
- si preflight pasa pero request falla, separa debug de auth/metodo
- si requests se cuelgan, revisa socket y estado daemon runtime

## Enlaces relacionados

- [Ejecutar y probar](./ejecutar-y-probar.md)
- [Desplegar a produccion](./desplegar-a-produccion.md)
- [Arquitectura](../explicacion/arquitectura.md)
