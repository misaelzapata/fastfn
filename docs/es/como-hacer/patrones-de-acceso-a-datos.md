# Patrones de Acceso a Datos

> Estado verificado al **13 de marzo de 2026**.

## Vista rapida

- Complejidad: Intermedio
- Tiempo tipico: 20-30 minutos
- Resultado: patrones consistentes para SQL, SQL async y NoSQL

## Patron SQL base

Principios:

- config en env
- inicializacion lazy del cliente
- timeout acotado por query

Path neutral de ejemplo: `functions/orders/get.*`

```bash
curl -sS 'http://127.0.0.1:8080/orders?id=1'
```

## Patron SQL async

Usa librerias async para cargas IO-heavy, manteniendo el mismo envelope HTTP.

Contrato minimo:

- `200` con `data`
- `404` cuando falta registro
- `500` con codigo de error no sensible

## Patron adaptador NoSQL

Interfaz estable:

- `get_by_id(id)`
- `list(filters)`
- `upsert(record)`

Asi puedes cambiar backend sin romper contrato de handler.

## Validacion

- queries con timeout bounded
- faltante devuelve `404` deterministico
- cambio SQL/NoSQL no rompe envelope

## Troubleshooting

- si falla conexion en native, valida reachability local
- si sube latencia, logea duracion query y tamano payload
- si hay drift de schema, aplica versionado/migraciones en registros

## Enlaces relacionados

- [Configuracion y secretos](../tutorial/desde-cero/3-configuracion-y-secretos.md)
- [Ejecutar y probar](./ejecutar-y-probar.md)
- [Estructura app grande](./estructura-app-grande.md)
