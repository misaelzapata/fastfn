# Demo Bot de WhatsApp (Sesion Real)


> Estado verificado al **10 de marzo de 2026**.
> Nota de runtime: FastFN auto-instala dependencias locales por función desde `requirements.txt` / `package.json`; en `fastfn dev --native` necesitas runtimes instalados en host, mientras que `fastfn dev` depende de Docker daemon activo.
Esta guia ejecuta una sesion real de WhatsApp Web desde una funcion Node.

## 1. Iniciar plataforma

```bash
docker compose up -d --build
```

## 2. Probar primero el demo QR

```bash
curl -sS 'http://127.0.0.1:8080/qr?text=HolaQR' -o /tmp/qr.svg
```

## 3. Ver intro del demo WhatsApp

```bash
curl -sS 'http://127.0.0.1:8080/whatsapp' | jq .
```

## 4. Pedir QR (auto-inicia conexion)

```bash
curl -sS 'http://127.0.0.1:8080/whatsapp?action=qr' --output /tmp/wa-qr.png
```

Escanea `/tmp/wa-qr.png` desde WhatsApp:
- `Configuracion`
- `Dispositivos vinculados`
- `Vincular dispositivo`

## 5. Ver estado de sesion

```bash
curl -sS 'http://127.0.0.1:8080/whatsapp?action=status' | jq .
```

Debes ver:
- `"connected": true`
- `"me": "<jid>"`

## 6. Enviar mensaje

```bash
curl -sS -X POST 'http://127.0.0.1:8080/whatsapp?action=send' \
  -H 'Content-Type: application/json' \
  --data '{"to":"15551234567","text":"hola desde FastFN"}' | jq .
```

## 7. Leer inbox/outbox

```bash
curl -sS 'http://127.0.0.1:8080/whatsapp?action=inbox' | jq .
curl -sS 'http://127.0.0.1:8080/whatsapp?action=outbox' | jq .
```

## 8. Respuesta AI (opcional)

Configura `fn.env.json` de la funcion:

`<FN_FUNCTIONS_ROOT>/whatsapp/fn.env.json`

```json
{
  "OPENAI_API_KEY": {"value":"sk-...","is_secret":true},
  "OPENAI_MODEL": {"value":"gpt-4o-mini","is_secret":false}
}
```

Luego:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/whatsapp?action=chat' \
  -H 'Content-Type: application/json' \
  --data '{"to":"15551234567","text":"Responde breve y amable en espanol"}' | jq .
```

### 8.1 Tools y auto-tools en WhatsApp

Ver también: [Herramientas (Función-a-Función + HTTP Limitado)](../como-hacer/herramientas.md)

Agrega env opcional en `<FN_FUNCTIONS_ROOT>/whatsapp/fn.env.json`:

```json
{
  "WHATSAPP_TOOLS_ENABLED": {"value":"true","is_secret":false},
  "WHATSAPP_AUTO_TOOLS": {"value":"true","is_secret":false},
  "WHATSAPP_TOOL_ALLOW_FN": {"value":"request-inspector,telegram-ai-digest","is_secret":false},
  "WHATSAPP_TOOL_ALLOW_HTTP_HOSTS": {"value":"api.ipify.org,wttr.in,ipapi.co","is_secret":false},
  "WHATSAPP_TOOL_TIMEOUT_MS": {"value":"5000","is_secret":false}
}
```

Directivas manuales:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/whatsapp?action=chat' \
  -H 'Content-Type: application/json' \
  --data '{"text":"Usa [[http:https://api.ipify.org?format=json]] y [[fn:request-inspector?key=wa|GET]]"}' | jq .
```

Auto-tools desde texto natural:

```bash
curl -sS -X POST 'http://127.0.0.1:8080/whatsapp?action=chat' \
  -H 'Content-Type: application/json' \
  --data '{"text":"Como esta el clima hoy y cual es mi IP?"}' | jq .
```

## 9. Resetear sesion

```bash
curl -sS -X DELETE 'http://127.0.0.1:8080/whatsapp?action=reset-session' | jq .
```

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

- [Especificación de Funciones](../referencia/especificacion-funciones.md)
- [Referencia API HTTP](../referencia/api-http.md)
- [Checklist Ejecutar y Probar](../como-hacer/ejecutar-y-probar.md)
