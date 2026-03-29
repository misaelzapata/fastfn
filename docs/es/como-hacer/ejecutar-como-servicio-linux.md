# Ejecutar FastFN como servicio Linux

> Estado verificado al **27 de marzo de 2026**.

La forma simple de pensarlo es esta:

1. corre FastFN como servicio `systemd` en `127.0.0.1`
2. pon un frontend chico delante para tráfico público
3. deja que ese frontend maneje TLS

Si quieres la historia más simple para certificados, usa Caddy delante de FastFN.
Si ya usas OpenResty o Nginx, proxyalo desde ahí.

## Forma recomendada

```text
Internet
  -> Caddy / OpenResty / Nginx
  -> FastFN en 127.0.0.1:8080
  -> tus funciones
```

FastFN queda simple:

- `fastfn run --native /srv/mi-app`
- health en `/_fn/health`
- tráfico de app en un solo puerto local

## 1. Crear un usuario dedicado

```bash
sudo useradd --system --home /srv/fastfn --shell /usr/sbin/nologin fastfn
sudo mkdir -p /srv/fastfn/app
sudo chown -R fastfn:fastfn /srv/fastfn
```

## 2. Poner la app en disco

Ejemplo:

```text
/srv/fastfn/app/
├── fastfn.json
├── fn.config.json
├── dist/
└── api/
```

## 3. Crear el servicio systemd

`/etc/systemd/system/fastfn.service`

```ini
[Unit]
Description=FastFN
After=network.target

[Service]
Type=simple
User=fastfn
Group=fastfn
WorkingDirectory=/srv/fastfn/app
Environment=FN_HOT_RELOAD=0
Environment=FN_HOST_PORT=8080
Environment=FN_PUBLIC_BASE_URL=https://api.example.com
ExecStart=/usr/local/bin/fastfn run --native /srv/fastfn/app
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

Luego:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fastfn
sudo systemctl status fastfn
```

## 4. Health check

Desde el mismo servidor:

```bash
curl -sS http://127.0.0.1:8080/_fn/health
```

## 5. TLS: camino más simple con Caddy

Si quieres la configuración más fácil para certificados, pon Caddy delante.
Caddy maneja Let's Encrypt automáticamente.

`/etc/caddy/Caddyfile`

```caddy
api.example.com {
  reverse_proxy 127.0.0.1:8080
}
```

Luego:

```bash
sudo systemctl enable --now caddy
```

Este es el camino más simple porque:

- no tienes que manejar paths manuales de certificados
- no te montas tu propia renovación con certbot
- FastFN se queda escuchando solo en localhost

## 6. Si ya usas OpenResty o Nginx

También está perfecto. Deja que OpenResty maneje TLS y reenvíe a FastFN.

```nginx
upstream fastfn_upstream {
  server 127.0.0.1:8080;
  keepalive 32;
}

server {
  listen 443 ssl http2;
  server_name api.example.com;

  ssl_certificate /etc/letsencrypt/live/api.example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/api.example.com/privkey.pem;

  location / {
    proxy_pass http://fastfn_upstream;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }

  location ^~ /_fn/ {
    allow 127.0.0.1;
    deny all;
    proxy_pass http://fastfn_upstream;
  }

  location ^~ /console/ {
    allow 127.0.0.1;
    deny all;
    proxy_pass http://fastfn_upstream;
  }
}
```

El camino más simple ahí es Let's Encrypt con Certbot:

```bash
sudo certbot --nginx -d api.example.com
```

O usa tus certificados actuales si ya los gestionas por otro lado.

## 7. ¿Se puede correr “solo FastFN” sin frontend?

Sí, pero solo cuando TLS no sea tu problema:

- LAN privada
- acceso solo por VPN
- otro load balancer termina TLS antes

Para tráfico público en internet, un frontend que termine TLS sigue siendo el default más simple y más seguro.

## 8. Buenos defaults

- deja FastFN bind en `127.0.0.1`
- deja `FN_HOT_RELOAD=0` en modo servicio
- define `FN_PUBLIC_BASE_URL` con la URL HTTPS real
- no expongas `/_fn/*` ni `/console/*` públicamente

## Ver también

- [Desplegar a Producción](./desplegar-a-produccion.md)
- [Checklist de seguridad](./checklist-seguridad-produccion.md)
- [Recetas Operativas](./recetas-operativas.md)
