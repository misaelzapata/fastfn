# Flujos visuales


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
## Flujo de invocación pública

```mermaid
flowchart LR
  A["Request cliente"] --> B["OpenResty ruta pública"]
  B --> C{"¿Método permitido?"}
  C -- "No" --> D["405 + header Allow"]
  C -- "Sí" --> E{"¿Body/concurrencia válidos?"}
  E -- "No" --> F["413 o 429"]
  E -- "Sí" --> G["Construir event + context"]
  G --> H["Runtime por socket Unix"]
  H --> I{"¿Respuesta runtime válida?"}
  I -- "No" --> J["502"]
  I -- "Sí" --> K["Respuesta HTTP final"]
```

## Flujo interno (`/_fn/invoke`)

```mermaid
flowchart LR
  A["Payload invoke consola/API"] --> B["/_fn/invoke"]
  B --> C["Validar método/política"]
  C --> D["Inyectar context.user"]
  D --> E["Enrutar por router del gateway"]
  E --> F["Misma política que tráfico externo"]
  F --> G["Ejecución runtime"]
  G --> H["Respuesta JSON envuelta"]
```

## Mapeo de errores

```mermaid
flowchart TD
  A["Llamada gateway"] --> B{"Runtime disponible?"}
  B -- "No" --> C["503 runtime down"]
  B -- "Sí" --> D{"¿Timeout?"}
  D -- "Sí" --> E["504 timeout"]
  D -- "No" --> F{"¿Contrato runtime válido?"}
  F -- "No" --> G["502 respuesta inválida"]
  F -- "Sí" --> H["Devolver status/body de función"]
```

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
