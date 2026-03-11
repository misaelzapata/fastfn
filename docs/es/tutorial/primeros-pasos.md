# Inicio Rápido


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
¡Bienvenido a FastFN! Esta guía es la forma más rápida de experimentar la magia del enrutamiento basado en archivos y la generación automática de OpenAPI.

Si vienes de FastAPI o de las rutas API de Next.js, te sentirás como en casa: suelta un archivo, obtén un endpoint. Cero boilerplate.

## 1. Inicializa tu proyecto

Vamos a construir tu primer endpoint de API. En FastFN, tu estructura de carpetas es tu API. Abre tu terminal y ejecuta:

```bash
fastfn init hello --template node
```

Esto crea `node/hello/` con un archivo `handler.js`. ¡Eso es todo! Acabas de crear un endpoint de API.

## 2. Inicia el servidor de desarrollo

Inicia FastFN en tu directorio actual:

```bash
fastfn dev .
```

Detrás de escena, FastFN levanta un gateway OpenResty, inicia los runtimes necesarios para los handlers descubiertos y mapea tus carpetas a rutas HTTP en vivo.

!!! note "Qué se instala automáticamente (y qué no)"
    - FastFN auto-instala dependencias por función desde `requirements.txt` / `package.json` junto al handler.
    - FastFN no instala runtimes del host (`python`, `node`, etc.).
    - En `fastfn dev` (modo portable), Docker debe estar activo.
    - En `fastfn dev --native`, necesitas OpenResty + runtimes instalados en el host.

## 3. Mira la Magia: Documentación Interactiva Automática

FastFN genera automáticamente documentación OpenAPI 3.1 para cada función que creas.

Abre tu navegador y navega a:
👉 **[http://127.0.0.1:8080/docs](http://127.0.0.1:8080/docs)**

![Swagger UI mostrando rutas de FastFN](../../assets/screenshots/swagger-ui.png)

¡Puedes probar tu endpoint directamente desde esta interfaz! Haz clic en la ruta `GET /hello`, haz clic en "Try it out" y presiona "Execute".

## 4. Llama a tu API

También puedes llamar a tu nuevo endpoint usando tu navegador o `curl`:

```bash
curl -i 'http://127.0.0.1:8080/hello?name=Mundo'
```

**Salida Esperada:**
```json
{
  "status": 200,
  "body": "Hello Mundo"
}
```

### Atajo de respuesta sencilla

En `node`, `php` y `lua` puedes devolver un valor directo (sin envelope completo) y FastFN lo normaliza.

Ejemplo (Node):

```js
exports.handler = async () => "Hello Mundo";
```

Resultado para `GET /hello`:

- HTTP `200`
- `Content-Type: text/plain; charset=utf-8`
- body: `Hello Mundo`

Para mantener portabilidad entre runtimes (incluyendo `go` y `rust`), conviene usar `{ status, headers, body }` explicito.

## 5. Detén el servidor

Cuando hayas terminado, simplemente presiona `Ctrl+C` en la terminal donde se está ejecutando `fastfn dev` para detener el servidor limpiamente.

## Siguientes Pasos

¿Notaste cómo no tuviste que escribir ninguna lógica de enrutamiento ni configurar un servidor?
- Aprende a usar parámetros dinámicos en [Enrutamiento y Parámetros](./routing.md).
- Profundiza con nuestro [Curso Desde Cero](./desde-cero/index.md).

## Objetivo

Alcance claro, resultado esperado y público al que aplica esta guía.

## Prerrequisitos

- CLI de FastFN disponible
- Dependencias por modo verificadas (Docker para `fastfn dev`, OpenResty+runtimes para `fastfn dev --native`)

## Checklist de Validación

- Los comandos de ejemplo devuelven estados esperados
- Las rutas aparecen en OpenAPI cuando aplica
- Las referencias del final son navegables

## Solución de Problemas

- Si un runtime cae, valida dependencias de host y endpoint de health
- Si faltan rutas, vuelve a ejecutar discovery y revisa layout de carpetas

## Ver también

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
