<?php

function handler(array $event): array
{
    $query = $event['query'] ?? [];
    $env = $event['env'] ?? [];
    $name = $query['name'] ?? 'world';
    $prefix = $env['PHP_GREETING'] ?? 'php';

    return [
        'status' => 200,
        'headers' => [
            'Content-Type' => 'application/json',
        ],
        'body' => json_encode([
            'runtime' => 'php',
            'function' => 'php-profile',
            'hello' => $prefix . '-' . $name,
        ], JSON_UNESCAPED_SLASHES),
    ];
}
