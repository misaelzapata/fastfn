# Versioned API with Deep Nesting

Demonstrates zero-config routing with 4+ levels of nesting for API versioning.

## Structure

```
api/
  v1/
    users/
      index.js         GET /api/v1/users
      [id].js          GET /api/v1/users/:id
    health/
      index.py         GET /api/v1/health
  v2/
    users/
      index.js         GET /api/v2/users  (updated response)
      [id].js          GET /api/v2/users/:id
```

## Run

```bash
fastfn dev examples/functions/versioned-api
```

## Test

```bash
# v1 endpoints
curl http://127.0.0.1:8080/api/v1/users
curl http://127.0.0.1:8080/api/v1/users/42
curl http://127.0.0.1:8080/api/v1/health

# v2 endpoints (updated response format)
curl http://127.0.0.1:8080/api/v2/users
curl http://127.0.0.1:8080/api/v2/users/42
```
