# Plantilla de handler PHP

El runtime PHP ya esta implementado. Usa esta plantilla para `app.php` o `handler.php`.

```php title="php-handler.php"
<?php

function handler(array $event): array {
    $query = $event['query'] ?? [];
    $name = $query['name'] ?? 'mundo';

    return [
        'status' => 200,
        'headers' => [
            'Content-Type' => 'application/json',
        ],
        'body' => json_encode([
            'runtime' => 'php',
            'hello' => $name,
        ]),
    ];
}
```
