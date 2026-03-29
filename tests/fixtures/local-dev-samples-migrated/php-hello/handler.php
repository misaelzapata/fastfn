<?php

function handler(array $event): array {
    return [
        'status' => 200,
        'headers' => [
            'Content-Type' => 'application/json',
        ],
        'body' => json_encode([
            'message' => 'Hello from PHP!',
            'runtime' => 'php'
        ]),
    ];
}
