# Parte 1: Configuración y tu Primera Ruta


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
¡Bienvenido al curso de FastFN! En esta primera parte, configuraremos nuestro proyecto "Task Manager API" y crearemos un endpoint que devuelva una lista de tareas.

## 1. Crear el Proyecto

Empecemos creando una carpeta para nuestra API e inicializando nuestra primera función. Abre tu terminal y ejecuta:

```bash
mkdir task-manager-api
cd task-manager-api
fastfn init tasks --template node
```

Esto crea una carpeta `tasks` con un archivo `handler.js`. En FastFN, tu estructura de carpetas es tu API. La carpeta `tasks` se convierte automáticamente en el endpoint `/tasks`.

## 2. Escribir el Código

Abre `tasks/handler.js` (o `.py`, `.php`, `.rs` dependiendo de tu lenguaje preferido) y reemplaza su contenido con el siguiente código:

=== "Python"
    ```python
    def handler(event):
        tasks = [
            {"id": 1, "title": "Aprender FastFN", "completed": False},
            {"id": 2, "title": "Construir una API", "completed": False}
        ]

        return {
            "status": 200,
            "body": tasks
        }
    ```

=== "Node.js"
    ```javascript
    exports.handler = async (event) => {
        const tasks = [
            { id: 1, title: "Aprender FastFN", completed: false },
            { id: 2, title: "Construir una API", completed: false }
        ];

        return {
            status: 200,
            body: tasks
        };
    };
    ```

=== "PHP"
    ```php
    <?php
    return function($event) {
        $tasks = [
            ["id" => 1, "title" => "Aprender FastFN", "completed" => false],
            ["id" => 2, "title" => "Construir una API", "completed" => false]
        ];

        return [
            "status" => 200,
            "body" => $tasks
        ];
    };
    ```

### Qué significa este código
- **`handler`**: La función de entrada que FastFN ejecuta.
- **`status: 200`**: El código de respuesta HTTP exitoso.
- **`body`**: El payload. ¡FastFN serializa automáticamente arrays y objetos a JSON por ti!

## 3. Iniciar el Servidor

Inicia el servidor de desarrollo de FastFN desde la raíz de tu carpeta `task-manager-api`:

```bash
fastfn dev .
```

Abre tu navegador y navega a `http://127.0.0.1:8080/tasks`. ¡Deberías ver tu lista de tareas devuelta como JSON!

![Navegador mostrando la respuesta JSON en /tasks](../../../assets/screenshots/browser-json-tasks.png)

## Siguientes Pasos

Ahora tienes un endpoint de API funcional. En la siguiente parte, aprenderemos cómo obtener una tarea específica usando enrutamiento dinámico (`/tasks/1`) y cómo añadir nuevas tareas leyendo el cuerpo de la petición.

[Ir a la Parte 2: Enrutamiento y Datos :arrow_right:](./2-enrutamiento-y-datos.md)

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
