# Capitulo 9 - Compartir Dependencias y Config Comun

Objetivo: evitar duplicar instalaciones y configurar varias funciones facil.

## Compartir `node_modules` / deps

Usa packs con `shared_deps` en `fn.config.json`:

```json
{
  "shared_deps": ["qrcode_pack"]
}
```

Estructura:

`<FN_FUNCTIONS_ROOT>/.fastfn/packs/node/qrcode_pack/package.json`

## Config ENV comun (patron simple)

Cada funcion mantiene su `fn.env.json` propio. Para valores comunes:

- usa plantilla base en tu repo interno
- merge por script de CI/CD
- sobreescribe solo claves por funcion

Esto mantiene simpleza y evita hardcodeos.
