<?php

function handler(array $event): array
{
    $query = $event['query'] ?? [];
    $name = $query['name'] ?? 'friend';
    $score = strlen((string)$name) * 10;

    return [
        'status' => 200,
        'headers' => [
            'Content-Type' => 'application/json',
        ],
        'body' => json_encode([
            'step' => 3,
            'runtime' => 'php',
            'name' => $name,
            'score' => $score,
            'message' => "PHP scored {$name} with {$score}",
        ], JSON_UNESCAPED_SLASHES),
    ];
}
