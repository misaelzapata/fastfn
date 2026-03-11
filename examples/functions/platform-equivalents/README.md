# Platform-Equivalent Advanced Examples

This package groups advanced serverless patterns frequently shown in major platforms, implemented with FastFN file routing and polyglot handlers.

Verified status as of **March 10, 2026**.

## Pattern Mapping

| Common pattern in other platforms | FastFN equivalent in this package |
| --- | --- |
| Header/API-key auth and middleware guards | `POST /auth/login` + `GET /auth/profile` |
| Signed webhook verification (GitHub/Stripe style) | `POST /webhooks/github-signed` |
| Async/background job kickoff with polling | `POST /jobs/render-report` + `GET /jobs/render-report/:id` |
| Versioned CRUD API with validation and status transitions | `/api/v1/orders` family |

References (official docs):

- Cloudflare Workers auth examples: https://developers.cloudflare.com/workers/examples/auth-with-headers/
- Cloudflare signed requests example: https://developers.cloudflare.com/workers/examples/signing-requests/
- Netlify function examples (background/scheduled patterns): https://docs.netlify.com/build/functions/lambda-compatibility/
- Vercel functions docs and patterns: https://vercel.com/docs/functions
- AWS Lambda sample apps: https://docs.aws.amazon.com/lambda/latest/dg/lambda-samples.html

## Structure

```text
auth/
  post.login.js             POST /auth/login
  get.profile.py            GET  /auth/profile

webhooks/
  post.github-signed.py     POST /webhooks/github-signed

jobs/
  render-report/
    post.js                 POST /jobs/render-report
    [id]/
      get.php               GET  /jobs/render-report/:id

api/
  v1/
    orders/
      get.js                GET  /api/v1/orders
      post.py               POST /api/v1/orders
      [id]/
        get.php             GET  /api/v1/orders/:id
        put.js              PUT  /api/v1/orders/:id
```

## Run

```bash
bin/fastfn dev examples/functions/platform-equivalents
```

If Docker is not running, use:

```bash
bin/fastfn dev --native examples/functions/platform-equivalents
```

## Quick Test

### 1) Login + profile

```bash
TOKEN="$(curl -sS -X POST 'http://127.0.0.1:8080/auth/login' \
  -H 'content-type: application/json' \
  --data '{"username":"demo-admin","role":"admin"}' | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"

curl -sS 'http://127.0.0.1:8080/auth/profile' \
  -H "authorization: Bearer ${TOKEN}"
```

### 2) Signed webhook + idempotency

```bash
PAYLOAD='{"action":"opened","repository":"fastfn"}'
SIG="$(python3 - <<'PY'
import hashlib, hmac
secret=b"fastfn-webhook-secret"
body=b'{"action":"opened","repository":"fastfn"}'
print("sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest())
PY
)"

curl -sS -X POST 'http://127.0.0.1:8080/webhooks/github-signed' \
  -H "x-hub-signature-256: ${SIG}" \
  -H 'x-github-delivery: demo-1' \
  -H 'content-type: application/json' \
  --data "${PAYLOAD}"
```

### 3) Orders API (create/list/get/update)

```bash
ORDER_ID="$(curl -sS -X POST 'http://127.0.0.1:8080/api/v1/orders' \
  -H 'content-type: application/json' \
  --data '{"customer":"acme","items":[{"sku":"A-1","qty":2}]}' | \
  python3 -c 'import json,sys; print((json.load(sys.stdin)["order"] or {})["id"])')"

curl -sS 'http://127.0.0.1:8080/api/v1/orders'
curl -sS "http://127.0.0.1:8080/api/v1/orders/${ORDER_ID}"
curl -sS -X PUT "http://127.0.0.1:8080/api/v1/orders/${ORDER_ID}" \
  -H 'content-type: application/json' \
  --data '{"status":"shipped","tracking_number":"TRK-1001"}'
```

### 4) Async report job

```bash
JOB_JSON="$(curl -sS -X POST 'http://127.0.0.1:8080/jobs/render-report' \
  -H 'content-type: application/json' \
  --data '{"report_type":"sales","items":[1,2,3,4]}')"

POLL_URL="$(printf '%s' "${JOB_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["poll_url"])')"
curl -sS "http://127.0.0.1:8080${POLL_URL}"
sleep 3
curl -sS "http://127.0.0.1:8080${POLL_URL}"
```

