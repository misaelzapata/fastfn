# Run FastFN as a Linux Service

> Verified status as of **March 27, 2026**.

This is the simple production shape to remember:

1. run FastFN as a `systemd` service on `127.0.0.1`
2. put a small frontend in front of it for public traffic
3. let that frontend handle TLS

If you want the easiest certificate story, use Caddy in front of FastFN.
If you already run OpenResty or Nginx, proxy to FastFN from there.

## Recommended shape

```text
Internet
  -> Caddy / OpenResty / Nginx
  -> FastFN on 127.0.0.1:8080
  -> your functions
```

FastFN stays simple:

- `fastfn run --native /srv/my-app`
- health at `/_fn/health`
- app traffic on one local port

## 1. Create a dedicated user

```bash
sudo useradd --system --home /srv/fastfn --shell /usr/sbin/nologin fastfn
sudo mkdir -p /srv/fastfn/app
sudo chown -R fastfn:fastfn /srv/fastfn
```

## 2. Put your app on disk

Example:

```text
/srv/fastfn/app/
├── fastfn.json
├── fn.config.json
├── dist/
└── api/
```

## 3. Create the systemd service

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

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fastfn
sudo systemctl status fastfn
```

## 4. Health check

From the same server:

```bash
curl -sS http://127.0.0.1:8080/_fn/health
```

## 5. TLS: easiest path with Caddy

If you want the simplest certificate setup, put Caddy in front.
Caddy handles Let's Encrypt automatically.

`/etc/caddy/Caddyfile`

```caddy
api.example.com {
  reverse_proxy 127.0.0.1:8080
}
```

Then:

```bash
sudo systemctl enable --now caddy
```

This is the easiest setup because:

- no manual certificate paths
- no separate certbot cron to wire yourself
- FastFN stays on localhost

## 6. If you already use OpenResty or Nginx

This is also fine. Let OpenResty handle TLS and forward to FastFN.

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

The simplest cert path there is standard Let's Encrypt with Certbot:

```bash
sudo certbot --nginx -d api.example.com
```

Or use your existing cert files if you already manage them elsewhere.

## 7. Can you run “just FastFN” with no frontend?

Yes, but only when TLS is not your problem:

- private LAN
- VPN-only access
- another load balancer already terminates TLS

In that case, run the service and expose the port you need.

For public internet traffic, a frontend that terminates TLS is the simpler and safer default.

## 8. Good defaults

- keep FastFN bound to `127.0.0.1`
- keep `FN_HOT_RELOAD=0` in service mode
- set `FN_PUBLIC_BASE_URL` to the real HTTPS URL
- do not expose `/_fn/*` or `/console/*` publicly

## See also

- [Deploy to Production](./deploy-to-production.md)
- [Security Confidence](./security-confidence.md)
- [Operational Recipes](./operational-recipes.md)
