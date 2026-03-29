# Referencia CLI


> Estado verificado al **22 de marzo de 2026**.
> Nota de runtime: FastFN resuelve dependencias y build por función según el runtime: Python usa `requirements.txt`, Node usa `package.json`, PHP instala desde `composer.json` cuando existe, y Rust compila handlers con `cargo`. En `fastfn dev --native` necesitas runtimes y herramientas del host; `fastfn dev` depende de un daemon de Docker activo.
La CLI de **fastfn** es la entrada principal para desarrollo local, diagnóstico, docs y scaffolding.

## Checks rápidos

Ver la versión de la CLI:

```bash
fastfn version
fastfn --version
```

Formato actual de salida:

```text
FastFN <version>
```

## Instalación

Compila el binario y agrégalo a tu `PATH`:

```bash
make build-cli
export PATH="$PWD/bin:$PATH"
```

El binario queda en `./bin/fastfn`.

## Comandos

### `init`

Crea un scaffold inicial específico de runtime.

**Uso:**

```bash
fastfn init <name> -t <runtime>
```

**Argumentos:**

- `<name>`: nombre del directorio de la función.

**Flags:**

- `-t, --template`: `node` (default), `python`, `php`, `lua`, `rust` (experimental).

**Comportamiento del scaffold:**

- `fastfn init hello -t node` crea `./hello/` con `handler.js` y `fn.config.json`.
- `fastfn init hello -t python` crea `./hello/` con `handler.py`, `fn.config.json` y `requirements.txt`.

El scaffold usa layout path-neutral (sin prefijo de runtime). Todos los templates crean `handler.<ext>` con funcion `handler(event)`.

**Ejemplos:**

```bash
fastfn init hello -t node
fastfn init hello -t python
```

Archivos generados:

- `fn.config.json`
- `handler.<ext>` (`handler.js`, `handler.py`, `handler.php`, `handler.lua` o `handler.rs`)
- `requirements.txt` (solo Python)

### `dev`

Inicia el servidor de desarrollo con hot reload.

**Uso:**

```bash
fastfn dev [directory]
```

**Argumentos:**

- `[directory]`: root de funciones a escanear. Default: directorio actual, o `functions-dir` en `fastfn.json` si existe.

**Flags:**

- `--native`: corre en el host usando runtimes locales en vez de Docker.
- `--build`: rebuild de la imagen runtime antes de arrancar.
- `--dry-run`: imprime la config generada de Docker Compose y sale.
- `--force-url`: permite que rutas de config/policy sobrescriban URLs ya mapeadas.

**Ejemplos:**

```bash
fastfn dev .
fastfn dev functions
fastfn dev --native functions
```

### `run`

Inicia el stack con defaults orientados a produccion.

**Uso:**

```bash
fastfn run [directory] --native
```

**Flags:**

- `--native`: requerido hoy; el modo produccion con Docker todavia no esta cableado.
- `--force-url`: permite que rutas de config/policy sobrescriban URLs ya mapeadas.

Hot reload esta **habilitado por defecto**. Precedencia: flag `--hot-reload` > env `FN_HOT_RELOAD` > `hot-reload` en `fastfn.json` > default (`true`). Usa `FN_HOT_RELOAD=0` para desactivarlo.

### `doctor` / `check`

Corre diagnósticos del entorno y del proyecto. Devuelve código no cero si algún check falla.

**Uso:**

```bash
fastfn doctor [subcommand] [flags]
fastfn check [subcommand] [flags]
```

**Subcommands:**

- `domains`: valida DNS para dominios custom.

**Flags:**

- `--json`: salida JSON legible por máquina.
- `--fix`: aplica auto-fixes locales seguros cuando es posible.

**Ejemplos:**

```bash
fastfn doctor
fastfn doctor domains --domain api.example.com
fastfn check --json
```

### `logs`

Sigue logs de un stack FastFN en ejecución.

**Uso:**

```bash
fastfn logs
```

**Flags:**

- `--file`: destino de log nativo: `error|access|runtime|all` (default `all`).
- `--lines`: cantidad de líneas a mostrar (default `200`).
- `--no-follow`: imprime el estado actual y sale.
- `--native`: fuerza backend de logs nativo.
- `--docker`: fuerza backend de logs Docker.

**Ejemplos:**

```bash
fastfn logs --native --file error --lines 200
fastfn logs --native --file runtime --lines 100
```

Usa `--file runtime` cuando quieres ver el `stdout`/`stderr` completo de los handlers en modo native.

### `docs`

Abre Swagger UI local cuando el servidor ya está corriendo.

```bash
fastfn docs
```

## Notas

- `fastfn dev` es la entrada normal para desarrollo.
- `fastfn run --native` es el modo local más cercano a producción.
- `fastfn version` y `fastfn --version` son equivalentes.
- `fastfn init` crea scaffolds path-neutral con `handler.<ext>` como archivo de entrada.

## Ver también

- [Especificación de Funciones](especificacion-funciones.md)
- [Referencia API HTTP](api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
