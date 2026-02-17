# Primeros Pasos <small>🚀</small>

Bienvenido a **fastfn**. Esta guía te llevará desde cero hasta una plataforma serverless local completamente funcional en menos de **2 minutos**.

---

## 🎯 Qué estamos construyendo

No solo estamos ejecutando un script; estamos iniciando una **Plataforma FaaS Lista para Producción** localmente que incluye:

1.  **Gateway (OpenResty)**: Maneja enrutamiento, seguridad y balanceo de carga.
2.  **Workers (Python, Node.js, PHP, Lua, Rust)**: Procesos persistentes listos para ejecutar código.
3.  **Consola y Docs**: UI integrada para gestionar y probar tus funciones.

---

## 1. Iniciar la Plataforma ⚡️

Todo el sistema está contenerizado. No necesitas instalar Python, Node, PHP, Lua o Nginx en tu máquina. Solo Docker.

```bash
docker compose up -d --build
```

<div class="result" markdown>
:white_check_mark: **Listo.** La plataforma ahora está escuchando en el puerto `8080`.
</div>

!!! tip "Bajo el capó"
    `docker compose up` levanta OpenResty y los runtimes de lenguaje en el mismo servicio, conectados por Unix sockets.

---

## 2. Verificar Salud del Sistema 🏥

Antes de ejecutar código, asegurémonos de que el cerebro del sistema esté activo.

### Navegador

Abre **[http://127.0.0.1:8080/_fn/health](http://127.0.0.1:8080/_fn/health)**

### Terminal

```bash
curl -sS 'http://127.0.0.1:8080/_fn/health' | jq
```

**Salida Esperada:**
```json
{
  "runtimes": {
    "python": { "health": { "up": true } },
    "node":   { "health": { "up": true } },
    "php":    { "health": { "up": true } },
    "rust":   { "health": { "up": true } }
  }
}
```

Si ves `"up": true`, los workers están conectados al gateway vía Sockets Unix y esperan comandos.

---

## 3. Primer Demo: Generador QR 📞

La plataforma trae ejemplos listos. Empieza con QR:

**Petición:**
```bash
curl 'http://127.0.0.1:8080/qr?text=HolaQR' -o /tmp/qr.svg
```

Luego prueba una función JSON:

```bash
curl 'http://127.0.0.1:8080/hello?name=Mundo'
```

!!! question "¿Cómo sucedió eso?"
    1.  La petición llegó a **Nginx** en el puerto 8080.
    2.  Nginx vio `/fn/hello` y lo enrutó al **Controlador Lua**.
    3.  Lua verificó la función descubierta en `FN_FUNCTIONS_ROOT`.
    4.  Reenvió la petición al socket Unix del runtime resuelto.
    5.  El Worker ejecutó `handler()` y retornó el JSON.
    **Todo típicamente en < 5ms.**

---

## 4. Explora el Dashboard 🎛️

No tienes que usar `curl` para todo. Incluimos una consola visual.

Abre **[http://127.0.0.1:8080/console/wizard](http://127.0.0.1:8080/console/wizard)** (paso a paso para principiantes)

Desde aquí puedes:
*   Ver todas las funciones desplegadas.
*   Editar código en el navegador (si está habilitado).
*   **Probar funciones** con payloads JSON personalizados.
*   Ver logs de ejecución.

!!! note "Consola deshabilitada por defecto"
    La UI de consola está apagada a menos que la habilites:

    ```bash
    export FN_UI_ENABLED=1
    docker compose up -d --build
    ```

[Siguiente: Escribe Tu Primera Función :arrow_right:](./tu-primera-funcion.md){ .md-button .md-button--primary }

[Demo Bot de WhatsApp (QR login + enviar/recibir + AI) :arrow_right:](./demo-bot-whatsapp.md){ .md-button }
