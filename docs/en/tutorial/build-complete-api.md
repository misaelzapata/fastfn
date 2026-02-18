# Build a Complete API (End-to-End)

This tutorial creates a realistic endpoint with:

- `GET` and `POST`
- API key auth (header)
- JSON validation
- explicit HTTP status codes
- metadata hints for OpenAPI

We will create a Python function named `customer-profile`.

## 0) Requirements

- FastFN running on `http://127.0.0.1:8080`
- Console API enabled (`FN_CONSOLE_API_ENABLED=1`)
- Write access enabled (`FN_CONSOLE_WRITE_ENABLED=1`) or admin token

Note: `/_fn/*` is the admin/control-plane API.

## 1) Create the function

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function?runtime=python&name=customer-profile' \
  -X POST \
  -H 'Content-Type: application/json' \
  --data '{"methods":["GET","POST"],"summary":"Customer profile API"}'
```

## 2) Configure policy (methods, limits, OpenAPI examples)

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-config?runtime=python&name=customer-profile' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{
    "timeout_ms": 1800,
    "max_concurrency": 8,
    "max_body_bytes": 262144,
    "invoke": {
      "methods": ["GET", "POST"],
      "summary": "Read or update a customer profile",
      "query": {"id": "cli_100"},
      "body": "{\"email\":\"alice@example.com\"}"
    }
  }'
```

## 3) Store a secret in function env

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-env?runtime=python&name=customer-profile' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"API_SECRET":{"value":"demo-key-123","is_secret":true}}'
```

## 4) Upload working handler code

```bash
curl -sS 'http://127.0.0.1:8080/_fn/function-code?runtime=python&name=customer-profile' \
  -X PUT \
  -H 'Content-Type: application/json' \
  --data '{"code":"import json\\n\\n\\ndef j(status, payload):\\n    return {\\n        \\"status\\": status,\\n        \\"headers\\": {\\"Content-Type\\": \\"application/json\\"},\\n        \\"body\\": json.dumps(payload, separators=(\\",\\", \\":\\")),\\n    }\\n\\n\\ndef main(req):\\n    method = str(req.get(\\"method\\") or \\"GET\\").upper()\\n    query = req.get(\\"query\\") or {}\\n    headers = req.get(\\"headers\\") or {}\\n    env = req.get(\\"env\\") or {}\\n\\n    if headers.get(\\"x-api-key\\") != env.get(\\"API_SECRET\\"):\\n        return j(401, {\\"error\\": \\"unauthorized\\"})\\n\\n    if method == \\"GET\\":\\n        cid = query.get(\\"id\\")\\n        if not cid:\\n            return j(400, {\\"error\\": \\"missing query param id\\"})\\n        return j(200, {\\"id\\": cid, \\"name\\": \\"Alice Example\\", \\"tier\\": \\"gold\\", \\"active\\": True})\\n\\n    if method == \\"POST\\":\\n        raw = req.get(\\"body\\") or \\"{}\\"\\n        try:\\n            payload = json.loads(raw)\\n        except Exception:\\n            return j(400, {\\"error\\": \\"invalid json body\\"})\\n\\n        email = payload.get(\\"email\\") if isinstance(payload, dict) else None\\n        if not email:\\n            return j(422, {\\"error\\": \\"email is required\\"})\\n\\n        return j(200, {\\n            \\"updated\\": True,\\n            \\"email\\": email,\\n            \\"fields\\": sorted(list(payload.keys())) if isinstance(payload, dict) else [],\\n        })\\n\\n    return j(405, {\\"error\\": \\"method not allowed\\"})\\n"}'
```

## 5) Validate behavior

### Unauthorized (missing key)

```bash
curl -i -sS 'http://127.0.0.1:8080/customer-profile?id=cli_100'
```

Expected: `401`.

### Valid GET

```bash
curl -i -sS 'http://127.0.0.1:8080/customer-profile?id=cli_100' \
  -H 'x-api-key: demo-key-123'
```

Expected: `200` + JSON profile.

### Invalid POST (missing email)

```bash
curl -i -sS -X POST 'http://127.0.0.1:8080/customer-profile' \
  -H 'x-api-key: demo-key-123' \
  -H 'Content-Type: application/json' \
  --data '{}'
```

Expected: `422`.

### Valid POST

```bash
curl -i -sS -X POST 'http://127.0.0.1:8080/customer-profile' \
  -H 'x-api-key: demo-key-123' \
  -H 'Content-Type: application/json' \
  --data '{"email":"alice@example.com","tier":"gold"}'
```

Expected: `200` + updated payload summary.

## 6) Check OpenAPI / Swagger

- `GET /openapi.json` should include `/customer-profile`
- `GET /docs` should show request examples (query + body)

