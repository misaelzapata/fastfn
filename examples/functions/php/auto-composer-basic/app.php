<?php

declare(strict_types=1);

require_once __DIR__ . '/vendor/autoload.php';

use Ramsey\Uuid\Uuid;

function handler(array $event): array
{
    $id = Uuid::uuid4()->toString();
    $body = json_encode([
        'runtime' => 'php',
        'function' => 'auto-composer-basic',
        'uuid' => $id,
    ], JSON_UNESCAPED_SLASHES);

    return [
        'status' => 200,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => $body !== false ? $body : '{"runtime":"php","function":"auto-composer-basic"}',
    ];
}
