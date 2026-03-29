# Depuracion y solucion de problemas

> Estado verificado al **27 de marzo de 2026**.
> Nota de runtime: FastFN resuelve dependencias y build por funcion segun el runtime. Python usa `requirements.txt`, Node usa `package.json`, PHP instala desde `composer.json` cuando existe, y Rust compila handlers con `cargo`.

## Vista rapida

- Complejidad: Principiante
- Tiempo tipico: 10-15 minutos
- Úsala cuando: una ruta, runtime, asset o accion de consola no se comporta como esperas
- Resultado: puedes aislar el problema entre discovery, runtime, assets o documentacion

## Primer chequeo

Antes de perseguir un bug, responde estas cuatro preguntas:

1. ¿El request llega a FastFN?
2. ¿`/_fn/health` muestra el runtime en `up`?
3. ¿La ruta aparece en `/_fn/catalog` y `/_fn/openapi.json`?
4. ¿La ruta es de funcion, de asset o interna?

Si respondes eso rapido, la mayoria de los problemas se vuelven obvios.

## 404, 405, 502, 503

Usa estos sintomas como guia:

- `404`: la ruta no se descubrio, fue shadowed o pertenece a un path privado
- `405`: la ruta existe, pero el metodo no esta permitido por la policy o el nombre del archivo
- `502`: el gateway llego al runtime, pero el runtime devolvio una respuesta mal formada o fallo
- `503`: el runtime no esta disponible, esta unhealthy o falta

Comandos utiles:

```bash
curl -i 'http://127.0.0.1:8080/hello'
curl -sS 'http://127.0.0.1:8080/_fn/health' | jq
curl -sS 'http://127.0.0.1:8080/_fn/catalog' | jq '{mapped_routes, mapped_route_conflicts}'
curl -sS 'http://127.0.0.1:8080/_fn/openapi.json' | jq '.paths | keys'
```

## Que revisar primero

### Si una ruta responde 404

- confirma que el nombre del archivo y la carpeta siguen la convención de routing
- revisa si ya existe una ruta en conflicto
- confirma que no sea una ruta privada, ignorada o bajo un prefijo reservado
- vuelve a correr discovery reiniciando la stack o usando el flujo de reload si tu setup lo soporta

### Si una ruta responde 405

- confirma el prefijo del metodo en el nombre del archivo, por ejemplo `get.`, `post.`, `put.`
- confirma que `fn.config.json` no restrinja la lista de metodos
- confirma que el metodo del request sea el correcto

### Si ves 502 o 503

- revisa primero `/_fn/health`
- despues revisa los logs del runtime
- confirma que los binarios requeridos estan instalados en modo native
- confirma que el entrypoint existe y sigue dentro de la raiz de la funcion

### Si la consola se comporta raro

- confirma que los flags `FN_CONSOLE_*` esten definidos
- revisa si la UI es local-only
- confirma que existan cookies de login si el login esta habilitado

## Logs

FastFN captura la salida del handler y la expone en los lugares habituales:

- `fastfn dev`: salida del terminal
- modo native: `fastfn logs --native --file runtime`
- flujos de admin/consola: `/_fn/invoke` y `/_fn/logs`

Ejemplo:

```bash
fastfn logs --native --file runtime --lines 50
```

## Assets y SPA

Si falta una pagina o asset estatico:

- confirma que la carpeta de assets configurada existe
- confirma que el archivo esta dentro de la raiz de assets
- confirma que el request sea una navegacion si el fallback SPA esta activo
- confirma que el asset no supere el limite configurado

Si una API JSON devuelve HTML inesperadamente, el request puede estar entrando en la heuristica de navegacion SPA en vez de una ruta de funcion.

## Native vs Docker

- En `fastfn dev`, importan mas los logs del contenedor y la stack del gateway
- En `fastfn dev --native`, importan mas los binarios del host y los ejecutables de runtime
- Si el problema pasa solo en native, revisa `FN_*_BIN`, `FN_RUNTIME_SOCKETS` y `/_fn/health`

## Inferencia de dependencias

Si la inferencia de dependencias en Python o Node se comporta raro:

- revisa primero `metadata.dependency_resolution.infer_backend`
- si el backend es `pipreqs`, `detective` o `require-analyzer`, confirma que esa herramienta exista en el entorno donde corre el daemon
- recuerda que la inferencia externa es mas lenta que un manifiesto explicito y conviene usarla como conveniencia, no como unico flujo de produccion
- si ya conoces los paquetes, agrega `requirements.txt`, `package.json` o `#@requirements` y vuelve a correr

## Enlaces relacionados

- [Ejecutar y probar](./ejecutar-y-probar.md)
- [Obtener ayuda](./obtener-ayuda.md)
- [Variables de entorno](../referencia/variables-de-entorno.md)
- [Referencia completa de config](../referencia/fn-config-completo.md)
- [Arquitectura](../explicacion/arquitectura.md)
