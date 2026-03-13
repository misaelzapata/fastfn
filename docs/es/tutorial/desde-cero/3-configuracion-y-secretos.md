# Parte 3: Configuración y Secretos


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
Nuestra API de tareas ahora puede manejar peticiones dinámicas y leer datos. Pero en el mundo real, las APIs necesitan conectarse a bases de datos, servicios de terceros y usar tokens secretos.

FastFN proporciona dos archivos de configuración clave para gestionar esto: `fn.env.json` para secretos y `fn.config.json` para el comportamiento de la función.

## 1. Variables de Entorno (`fn.env.json`)

Nunca debes codificar secretos (como contraseñas de bases de datos o claves API) en tu código. FastFN usa un archivo `fn.env.json` en la raíz de tu proyecto para inyectar variables de entorno de forma segura.

Crea un archivo `fn.env.json` en la raíz de tu proyecto:

```json
{
  "DB_CONNECTION_STRING": "postgres://user:pass@localhost:5432/tasks_db",
  "API_KEY": "super-secret-key"
}
```

Ahora, actualiza tu `tasks/handler.js` para leer estas variables:

=== "Python"
    ```python
    import os

    def handler(event):
        # Acceder a las variables de entorno
        db_string = os.environ.get("DB_CONNECTION_STRING")
        
        return {
            "status": 200,
            "body": {"message": f"Conectado a: {db_string}"}
        }
    ```

=== "Node.js"
    ```javascript
    exports.handler = async (event) => {
        // Acceder a las variables de entorno
        const dbString = process.env.DB_CONNECTION_STRING;

        return {
            status: 200,
            body: { message: `Conectado a: ${dbString}` }
        };
    };
    ```

=== "PHP"
    ```php
    <?php
    return function($event) {
        // Acceder a las variables de entorno
        $dbString = getenv('DB_CONNECTION_STRING');
        
        return [
            "status" => 200,
            "body" => ["message" => "Conectado a: $dbString"]
        ];
    };
    ```

!!! warning "Seguridad"
    Asegúrate de añadir `fn.env.json` a tu `.gitignore`. ¡Nunca confirmes secretos en el control de versiones!

## 2. Configuración de la Función (`fn.config.json`)

A veces necesitas controlar cómo se comporta una función específica. Por ejemplo, podrías querer limitar los métodos HTTP permitidos o establecer un tiempo de espera personalizado.

Crea un archivo `fn.config.json` junto a tu `tasks/handler.js`:

```text
task-manager-api/
└── tasks/
    ├── handler.js
    └── fn.config.json  # -> Configuración específica para esta ruta
```

Añade la siguiente configuración a `tasks/fn.config.json`:

```json
{
  "methods": ["GET", "POST"],
  "timeout": 5000,
  "memory": 128
}
```

Esta configuración le dice a FastFN que:
- Solo permita peticiones `GET` y `POST` a `/tasks`.
- Agote el tiempo de espera de la función si tarda más de 5 segundos.
- Asigne 128MB de memoria (útil para despliegues en la nube).

## Siguientes Pasos

¡Nuestra API ahora es segura y configurable! En la parte final, aprenderemos cómo devolver respuestas avanzadas, como HTML, redirecciones y códigos de estado de error personalizados.

[Ir a la Parte 4: Respuestas Avanzadas :arrow_right:](./4-respuestas-avanzadas.md)

## Diagrama de Flujo

```mermaid
flowchart LR
  A["Request del cliente"] --> B["Discovery de rutas"]
  B --> C["Validación de políticas y método"]
  C --> D["Ejecución del handler runtime"]
  D --> E["Respuesta HTTP + paridad OpenAPI"]
```

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

- [Especificación de Funciones](../../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../../como-hacer/ejecutar-y-probar.md)

## 3. Capas de configuracion y overrides

Precedencia recomendada (menor a mayor):

1. defaults de proyecto (`fastfn.json`)
2. config por funcion (`fn.config.json`)
3. env runtime (`fn.env.json`/secret manager)
4. overrides al desplegar

Dejar esto explicito evita sorpresas entre local y produccion.
