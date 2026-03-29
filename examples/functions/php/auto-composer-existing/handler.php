<?php

declare(strict_types=1);

require_once __DIR__ . '/vendor/autoload.php';

use Psr\Log\NullLogger;

function handler(array $event): array
{
    $logger = new NullLogger();
    $logger->info('auto-composer-existing invoked');

    $body = json_encode([
        'runtime' => 'php',
        'function' => 'auto-composer-existing',
        'composer' => 'manifest-driven',
    ], JSON_UNESCAPED_SLASHES);

    return [
        'status' => 200,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => $body !== false ? $body : '{"runtime":"php","function":"auto-composer-existing"}',
    ];
}
