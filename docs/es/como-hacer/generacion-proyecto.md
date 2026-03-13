# Generacion de Proyecto

> Estado verificado al **13 de marzo de 2026**.

## Vista rapida

- Complejidad: Principiante
- Tiempo tipico: 5-10 minutos
- Resultado: starter reproducible con validacion de ruta + OpenAPI

## Generar starter

```bash
mkdir mi-fastfn-app
cd mi-fastfn-app
fastfn init hola -t node
fastfn dev
```

Validar:

```bash
curl -sS 'http://127.0.0.1:8080/hola'
curl -sS 'http://127.0.0.1:8080/openapi.json' | jq '.info'
```

## Que crea `init`

- config de proyecto (`fastfn.json`)
- raiz de funciones
- templates runtime
- layout compatible con discovery

## Validacion

- funcion nueva auto-descubierta
- request devuelve `200`
- OpenAPI incluye la ruta

## Troubleshooting

- si falta `fastfn`, instalar CLI y reabrir shell
- si falla native, instalar deps host o usar Docker mode

## Enlaces relacionados

- [Primeros pasos](../tutorial/primeros-pasos.md)
- [Tu primera funcion](../tutorial/tu-primera-funcion.md)
- [Instalacion con Homebrew](./homebrew.md)
