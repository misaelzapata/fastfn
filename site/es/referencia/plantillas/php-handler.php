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
