# Autenticación y Control de Acceso

> Estado verificado al **13 de marzo de 2026**.

## Vista rapida

- Complejidad: Intermedio
- Tiempo tipico: 15-20 minutos
- Resultado: gate simple por token, limites OAuth2 claros y estrategia de scopes

## 1) Token gate simple

Ejemplo minimo con API key:

```bash
curl -i 'http://127.0.0.1:8080/reports/1'
curl -i 'http://127.0.0.1:8080/reports/1' -H 'x-api-key: demo'
```

Contrato recomendado:

- sin token: `401`
- token invalido: `401`
- token valido: `200`

## 2) Limites OAuth2 en FastFN

FastFN no impone un framework OAuth2 unico. El patron recomendado es:

1. servicio emisor externo para tokens
2. verificacion en funciones FastFN
3. mapeo de claims a permisos internos

Esto cubre "OAuth2-like flow" sin acoplar la app a un stack especifico.

## 3) Scope mapping

Define scopes estables por dominio:

- `reports:read`
- `reports:write`
- `admin:config`

Mapea scope a autorizacion por ruta y devuelve `403` cuando no alcance.

## Validacion

- requests sin token o scope devuelven estado correcto (`401`/`403`).
- los scopes documentados son consistentes entre funciones.
- no se filtran secretos en errores.

## Troubleshooting

- Si scopes no aplican, revisa parseo de claim (`scope` separado por espacio/coma).
- Si el token parece valido pero falla, verifica reloj/sincronizacion para expiracion.

## Enlaces relacionados

- [Seguridad para funciones](../tutorial/seguridad-para-funciones.md)
- [Reutilizar auth y validacion](./reutilizar-auth-y-validacion.md)
- [Auth practica para funciones](../articulos/auth-practica-para-funciones.md)
