# Deploying to Production

## Quick View

- Complexity: Intermediate
- Typical time: 20-30 minutes
- Use this when: you are moving from local dev to production runtime
- Outcome: production run mode and edge hardening are correctly configured


FastFN is designed to run in production using the same engine as development, but with hot reload disabled and safer defaults.

## Production Modes

### 1. Self-Hosted (Bare Metal / VM)

The simplest way is to run the binary in `run` mode. This disables hot reload and file watchers.

**Command:**
```bash
fastfn run --native /path/to/your/functions
```

**Requirements:**
- FastFN binary on the host.
- OpenResty available in `PATH` (required by `--native`).
- Language runtimes installed on the host for any runtimes you plan to use (Python/Node/PHP).

If OpenResty is missing but Docker is installed, production `run --native` still fails (as expected).  
For development, you can use `fastfn dev` (Docker mode) while installing OpenResty for native prod flows.

### 2. Docker Container

FastFN currently supports production mode through `--native`. Docker-based production wiring is planned, but not the default yet.

## Health Checks

FastFN exposes a health check endpoint for load balancers (K8s, AWS ALB):

- `GET /_fn/health`
- Returns `200 OK`

## Environment Variables

Ensure you pass production secrets via env vars, not `fn.env.json`.

```bash
docker run -e DB_PASSWORD=secret ...
```

FastFN merges `fn.env.json` with actual environment variables, prioritizing the environment.

## Reverse Proxy With Existing Nginx

Assume you already have a website on Nginx and you want to forward only API paths to FastFN.

FastFN listens on an internal port (for example `127.0.0.1:8080`) and Nginx proxies requests to it.

### Minimal example

This keeps your existing site as-is and forwards `/api/` to FastFN:

```nginx
upstream fastfn_upstream {
  server 127.0.0.1:8080;
  keepalive 32;
}

server {
  listen 443 ssl;
  server_name example.com;

  # Your existing site:
  root /var/www/site;
  index index.html;

  # Forward API to FastFN:
  location ^~ /api/ {
    proxy_pass http://fastfn_upstream;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  }
}
```

### Lock down admin endpoints

Do not expose `/_fn/*` or `/console/*` publicly unless you also restrict them.

A simple option is IP allowlisting:

```nginx
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
```

### OpenAPI base URL behind Nginx

FastFN detects the public server URL from `X-Forwarded-Proto` and `X-Forwarded-Host`.

If you cannot (or do not want to) forward those headers, set:

- `FN_PUBLIC_BASE_URL=https://example.com`
