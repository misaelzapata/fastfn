# PHP Examples

This folder groups PHP demos that cover routing, Composer-based installs, and session patterns.

## Run

```bash
fastfn dev examples/functions/php
```

## Routes

| Route | Method | What it does |
|-------|--------|-------------|
| `/php-profile` | GET | Simple profile endpoint. `?name=World` |
| `/auto-composer-basic` | GET | Fresh Composer install (returns UUID via ramsey/uuid) |
| `/auto-composer-existing` | GET | Existing Composer project with dependencies |
| `/session-demo` | GET | Cookie/session inspection. Send `Cookie: session_id=abc123; theme=dark` |

## Handler contract

PHP handlers export a function:

```php
function handler(array $event): array {
    return [
        "status" => 200,
        "headers" => ["Content-Type" => "application/json"],
        "body" => json_encode(["hello" => "world"])
    ];
}
```

## Test

```bash
curl -sS 'http://127.0.0.1:8080/php-profile?name=Developer'
curl -sS http://127.0.0.1:8080/auto-composer-basic
curl -sS -H 'Cookie: session_id=abc123; theme=dark' http://127.0.0.1:8080/session-demo
```
