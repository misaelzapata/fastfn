<?php

function handler($event) {
    return [
        'status' => 200,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode([
            'runtime' => 'php',
            'title' => 'PHP profile endpoint',
            'summary' => 'Classic API route living beside the SPA shell.',
            'path' => '/api-profile',
        ]),
    ];
}
