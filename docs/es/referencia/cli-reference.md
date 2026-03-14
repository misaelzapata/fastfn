# Referencia CLI


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN resuelve dependencias y build por función según el runtime: Python usa `requirements.txt`, Node usa `package.json`, PHP instala desde `composer.json` cuando existe, y Rust compila handlers con `cargo`. En `fastfn dev --native` necesitas runtimes y herramientas del host; `fastfn dev` depende de un daemon de Docker activo.
La referencia oficial del CLI está disponible en inglés:

- [CLI Reference](../../en/reference/cli.md)

Se mantendrá una versión en español en este mismo documento.

## `logs`

Sigue logs de un stack FastFN en ejecución.

```bash
fastfn logs
fastfn logs --native --file runtime --lines 100
```

- `--file` admite `error|access|runtime|all`
- usa `runtime` para leer `stdout` y `stderr` completos del handler en modo native

## Contrato

Define la forma esperada de request/response, campos de configuración y garantías de comportamiento.

## Ejemplo End-to-End

Usa los ejemplos de esta página como plantillas canónicas para implementación y testing.

## Casos Límite

- Fallbacks ante configuración faltante
- Conflictos de rutas y precedencia
- Matices por runtime

## Ver también

- [Especificación de Funciones](especificacion-funciones.md)
- [Referencia API HTTP](api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
