# Versionado y Rollout <small>🚀</small>

En producción, a menudo necesitas actualizar una API sin romper a los clientes existentes. `fastfn` tiene soporte incorporado para **Versionado de Funciones**.

---

## 🎯 La Estrategia

Usaremos una estrategia de despliegue "Lado-a-Lado" (Side-by-Side):
1.  **V1 (Actual)**: La versión de producción actual.
2.  **V2 (Beta)**: Una nueva versión con cambios, accesible vía una etiqueta específica.

---

## 1. La Versión por Defecto (V1)

Supongamos que tienes una función `hello` en `functions/python/hello/app.py`.

```python
# functions/python/hello/app.py
def handler(context):
    return {"message": "Hola desde V1"}
```

Llájala:
```bash
curl 'http://127.0.0.1:8080/fn/hello'
```
**Salida:** `{"message": "Hola desde V1"}`

---

## 2. Desplegar Versión 2 (V2) 🆕

Para crear una nueva versión, simplemente crea una subcarpeta con el nombre de la versión.

**Estructura:**
```text
functions/
└── python/
    └── hello/
        ├── app.py       <-- Por defecto (V1)
        └── v2/          <-- Nueva Versión
            └── app.py
```

Creemos el código de V2:

**Archivo:** `functions/python/hello/v2/app.py`
```python
def handler(context):
    # V2 retorna una estructura diferente
    return {
        "status": "success",
        "data": {
            "greeting": "Hola desde V2 [BETA]"
        }
    }
```

---

## 3. Acceder a Versiones Específicas 🏷️

`fastfn` usa la sintaxis `@` en la URL.

### Llamar a V2 Explícitamente
```bash
curl 'http://127.0.0.1:8080/fn/hello@v2'
```

**Respuesta:**
```json
{
  "status": "success",
  "data": {
    "greeting": "Hola desde V2 [BETA]"
  }
}
```

### Llamar a la V1
La URL original sigue apuntando correctamente a `app.py` en la raíz.
```bash
curl 'http://127.0.0.1:8080/fn/hello'
```

**Respuesta:**
```json
{
  "message": "Hola desde V1"
}
```

---

## 4. Estrategia de Rollout 🔀

Este mecanismo permite una migración suave:

1.  **Desplegar V2**: Crea la carpeta `v2`. Ahora está viva en `@v2` pero nadie la usa aún.
2.  **Pruebas Internas**: Tu equipo de QA verifica `.../hello@v2`.
3.  **Migración de Clientes**: Actualiza tu frontend/app móvil para apuntar a `@v2`.
4.  **Deprecación**: Una vez que el tráfico de V1 cae a cero, puedes eliminar `functions/python/hello/app.py`.

!!! tip "Estructura de URL"
    El patrón siempre es `/fn/<nombre_funcion>@<version>`.
    Las versiones pueden tener cualquier nombre alfanumérico: `v2`, `beta`, `rc1`, `2023-10`.

[Siguiente: Autenticación y Secretos :arrow_right:](./auth-y-secretos.md){ .md-button .md-button--primary }
