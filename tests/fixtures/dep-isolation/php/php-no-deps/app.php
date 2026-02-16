<?php

function handler(array $event): array
{
    // Try to use a class that would only exist if a composer dep was installed
    $hasMonolog = class_exists('Monolog\\Logger');

    return [
        'status' => 200,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode([
            'ok' => true,
            'runtime' => 'php',
            'has_monolog' => $hasMonolog,
            'isolation_ok' => !$hasMonolog,
        ], JSON_UNESCAPED_SLASHES),
    ];
}
