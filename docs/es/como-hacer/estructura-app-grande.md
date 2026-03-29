# Estructura para App Grande

> Estado verificado al **13 de marzo de 2026**.

## Vista rapida

- Complejidad: Intermedio
- Tiempo tipico: 25 minutos
- Resultado: layout escalable con ownership claro y patron de tareas en background

## Estructura recomendada

```text
functions/
  _shared/
  api/
    users/
    orders/
  jobs/
    render-report/
  webhooks/
```

Guidelines:

- shared en `_shared`
- separar rutas API de jobs
- nombres explicitos por dominio/equipo
- si discovery parece ambiguo, revisa [Enrutamiento Zero-Config](./zero-config-routing.md) para las reglas de warnings por profundidad, prefijos reservados y seleccion de handlers

## Patron background/scheduler

Para trabajo fuera de request:

- trigger cron con payload minimo
- funcion toma unidad de trabajo
- idempotency key evita duplicados

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health'
```

## Validacion

- rutas API y jobs se descubren sin ambiguedad
- jobs idempotentes
- ownership mapea a carpetas

## Troubleshooting

- si hay colision de rutas, revisa profundidad y archivos por metodo
- si jobs duplican, agrega lock/idempotency key
- si shared crece demasiado, dividir por dominio para bajar acoplamiento

## Enlaces relacionados

- [Zero-config routing](./zero-config-routing.md)
- [Gestionar funciones](./gestionar-funciones.md)
- [Patrones de acceso a datos](./patrones-de-acceso-a-datos.md)
