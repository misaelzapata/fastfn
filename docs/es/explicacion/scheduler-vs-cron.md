# Scheduler vs Cron


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
FastFN tiene un scheduler built-in que puede auto-invocar funciones dentro del proceso del gateway. “Cron” es el concepto general de scheduling por tiempo (normalmente implementado por un proceso/servicio externo).

## TL;DR

- Scheduler de FastFN: config por función en `fn.config.json`, soporta **intervalos** (`every_seconds`) y **cron** (`cron` + `timezone`), con **retry/backoff** opcional.
- Sistemas tipo cron: suelen soportar timezones más ricos (nombres IANA), administración/historial de jobs, y ejecución de comandos arbitrarios (no solo funciones/HTTP).

## Correr “Cada X Minutos”

Usa `every_seconds`:

```json
{
  "schedule": {
    "enabled": true,
    "every_seconds": 300,
    "method": "GET",
    "query": { "action": "inc" }
  }
}
```

Regla rápida:

- `X minutos` = `every_seconds = X * 60`

## Correr “A las 9am” (Cron + Timezone)

FastFN soporta cron de 5 campos y 6 campos, y un `timezone` limitado:

- `UTC` (o `Z`)
- `local`
- offsets fijos como `-05:00`, `+02:00`

Ejemplo (diario a las 09:00 UTC):

```json
{
  "schedule": {
    "enabled": true,
    "cron": "0 9 * * *",
    "timezone": "UTC",
    "method": "GET"
  }
}
```

Ejemplo (diario a las 09:00 con offset fijo):

```json
{
  "schedule": {
    "enabled": true,
    "cron": "0 9 * * *",
    "timezone": "-05:00",
    "method": "GET"
  }
}
```

## Retry/Backoff (Built-In)

Habilita retries para fallas transitorias (429/503/5xx):

```json
{
  "schedule": {
    "enabled": true,
    "cron": "*/1 * * * * *",
    "timezone": "UTC",
    "retry": true
  }
}
```

## Observabilidad

- Snapshot API: `GET /_fn/schedules`
- Vista en consola: `/console/scheduler`

## Persistencia Entre Restarts

FastFN persiste el estado del scheduler (last/next/status/errors, y retries pendientes) en un archivo local dentro del root de funciones:

- default: `<FN_FUNCTIONS_ROOT>/.fastfn/scheduler-state.json`

Controles:

- `FN_SCHEDULER_PERSIST_ENABLED=0` deshabilita persistencia.
- `FN_SCHEDULER_PERSIST_INTERVAL` controla cada cuánto se escribe (segundos).
- `FN_SCHEDULER_STATE_PATH` permite override del path.

## Checklist

- [x] “Llamar una función cada X minutos”: `every_seconds`
- [x] Expresiones cron + timezone: `cron` + `timezone`
- [x] Retry/backoff built-in: `schedule.retry`
- [x] Persistir estado entre restarts: `.fastfn/scheduler-state.json`
- [x] Ver last/next/last_status/last_error: `/_fn/schedules` + Consola

## Límites Conocidos (Actual)

- No hay soporte completo de timezones IANA como `America/New_York` (solo `UTC`, `local`, offsets fijos).
- No es una cola distribuida de jobs (sin coordinación multi-nodo, sin garantías exactly-once).

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
