# Versionado y Rollout

FastFN soporta versiones lado-a-lado (por ejemplo `v2`) para poder publicar cambios sin romper a los clientes existentes.

## 1) Estructura de carpetas (runtime split)

El versionado se representa con una subcarpeta dentro de la funcion:

```text
functions/
  python/
    hello/
      app.py      # version default
      v2/
        app.py    # version v2
```

## 2) Ejemplo de codigo

Default (`functions/python/hello/app.py`):

```python
def main(req):
    name = (req.get("query") or {}).get("name", "World")
    return {"message": f"Hola desde V1, {name}"}
```

Version `v2` (`functions/python/hello/v2/app.py`):

```python
def main(req):
    name = (req.get("query") or {}).get("name", "World")
    return {"status": "success", "data": {"greeting": f"Hola desde V2, {name}"}}
```

## 3) Llamar default vs version

Default (si existe `app.py` en la raiz):

```bash
curl -sS 'http://127.0.0.1:8080/hello?name=World'
```

Version:

```bash
curl -sS 'http://127.0.0.1:8080/hello@v2?name=World'
```

## 4) Patron de rollout

1. Publica la carpeta `v2/`.
2. Prueba con `GET /hello@v2`.
3. Migra clientes gradualmente.
4. Elimina la version vieja cuando el trafico llegue a cero.

[Siguiente: Auth y Secretos](./auth-y-secretos.md){ .md-button .md-button--primary }
