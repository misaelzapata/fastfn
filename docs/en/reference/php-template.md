# PHP Handler Template

PHP runtime is implemented. Use this template for `app.php` or `handler.php`.

```php title="php-handler.php"
<?php

function handler(array $event): array {
    $query = $event['query'] ?? [];
    $name = $query['name'] ?? 'world';

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
