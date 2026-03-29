<?php

function next_style_json_response(array $payload): array
{
    return [
        'status' => 200,
        'headers' => [
            'Content-Type' => 'application/json',
        ],
        'body' => json_encode($payload, JSON_UNESCAPED_SLASHES),
    ];
}

function next_style_export_rows(): array
{
    return [
        ['id' => '10', 'source' => 'php-mod-style'],
        ['id' => '11', 'source' => 'raw-output'],
    ];
}

function next_style_render_csv(array $rows): string
{
    $lines = ["id,source"];
    foreach ($rows as $row) {
        $lines[] = ($row['id'] ?? '') . ',' . ($row['source'] ?? '');
    }
    return implode("\n", $lines) . "\n";
}

function next_style_profile_payload(array $event): array
{
    $params = $event['params'] ?? new stdClass();
    $id = is_array($params) ? ($params['id'] ?? null) : null;

    return [
        'route' => 'GET /php/profile/:id',
        'runtime' => 'php',
        'helper' => 'php/_shared.php',
        'params' => $params,
        'id' => $id,
    ];
}
