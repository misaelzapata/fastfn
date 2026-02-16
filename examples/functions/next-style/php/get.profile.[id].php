<?php

function handler(array $event): array
{
    return [
        'status' => 200,
        'headers' => [
            'Content-Type' => 'application/json',
        ],
        'body' => json_encode([
            'route' => 'GET /php/profile/:id',
            'runtime' => 'php',
            'params' => $event['params'] ?? new stdClass(),
        ], JSON_UNESCAPED_SLASHES),
    ];
}
