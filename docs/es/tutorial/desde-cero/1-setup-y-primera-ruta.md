# Parte 1: Setup y Primera Ruta

> Estado verificado al **13 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.

## Vista rápida

- Complejidad: Principiante
- Tiempo típico: 15-20 minutos
- Resultado: proyecto limpio con endpoint `GET /tasks` y entrada visible en OpenAPI

## 1. Setup limpio

```bash
mkdir -p task-manager-api
cd task-manager-api
fastfn init tasks --template node
```

Layout esperado:

```text
task-manager-api/
  node/
    tasks/
      handler.js
```

## 2. Implementa la primera ruta

Edita `node/tasks/handler.js`:

```js
exports.handler = async () => ({
  status: 200,
  body: [
    { id: 1, title: "Aprender FastFN", completed: false },
    { id: 2, title: "Publicar primer endpoint", completed: false }
  ]
});
```

## 3. Ejecuta local

```bash
fastfn dev .
```

## 4. Valida primera request

```bash
curl -sS 'http://127.0.0.1:8080/tasks'
```

Body esperado:

```json
[
  { "id": 1, "title": "Aprender FastFN", "completed": false },
  { "id": 2, "title": "Publicar primer endpoint", "completed": false }
]
```

## 5. Valida visibilidad OpenAPI

```bash
curl -sS 'http://127.0.0.1:8080/openapi.json' | jq '.paths | has("/tasks")'
```

Salida esperada:

```text
true
```

![Navegador mostrando la respuesta JSON en /tasks](../../../assets/screenshots/browser-json-tasks.png)

## Solución de problemas

- `curl` devuelve `503`: revisa `/_fn/health` y dependencias runtime faltantes
- ruta no encontrada: confirma que el archivo esté en `node/tasks/handler.js`
- path ausente en OpenAPI: recarga con `curl -X POST http://127.0.0.1:8080/_fn/reload`

## Próximo paso

[Ir a la Parte 2: Enrutamiento y Datos](./2-enrutamiento-y-datos.md)

## Enlaces relacionados

- [Validación y schemas](../validacion-y-schemas.md)
- [Referencia API HTTP](../../referencia/api-http.md)
- [Ejecutar y probar](../../como-hacer/ejecutar-y-probar.md)
