<?php

function json_response(int $status, array $payload): array
{
    return [
        'status' => $status,
        'headers' => [
            'Content-Type' => 'application/json',
        ],
        'body' => json_encode($payload, JSON_UNESCAPED_SLASHES),
    ];
}

function parse_json_body($raw): array
{
    if (is_array($raw)) {
        return $raw;
    }
    if (!is_string($raw) || $raw === '') {
        return [];
    }
    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        return [];
    }
    return $decoded;
}

function resolve_internal_update_path(array $event, string $id): string
{
    $reqPath = (string)($event['path'] ?? '');
    $suffix = '/items/' . $id;
    $prefix = '';
    if ($reqPath !== '' && str_ends_with($reqPath, $suffix)) {
        $prefix = substr($reqPath, 0, strlen($reqPath) - strlen($suffix));
    }
    return $prefix . '/internal/items/' . rawurlencode($id);
}

function parse_http_status(array $headers): int
{
    if (count($headers) === 0) {
        return 502;
    }
    if (!preg_match('/\s(\d{3})\s/', $headers[0], $m)) {
        return 502;
    }
    return (int)$m[1];
}

function handler(array $event): array
{
    $params = $event['params'] ?? [];
    $id = trim((string)($params['id'] ?? ''));
    if ($id === '') {
        return json_response(400, ['error' => 'id is required']);
    }

    $body = parse_json_body($event['body'] ?? '');
    $name = trim((string)($body['name'] ?? ''));
    if ($name === '') {
        return json_response(400, ['error' => 'name is required']);
    }

    $internalPath = resolve_internal_update_path($event, $id);
    $url = 'http://127.0.0.1:8080' . $internalPath;
    $payload = json_encode(['name' => $name], JSON_UNESCAPED_SLASHES);
    $context = stream_context_create([
        'http' => [
            'method' => 'PUT',
            'header' => "Content-Type: application/json\r\nx-fastfn-internal-call: 1\r\n",
            'content' => $payload,
            'ignore_errors' => true,
            'timeout' => 4,
        ],
    ]);

    $raw = @file_get_contents($url, false, $context);
    if (!is_string($raw)) {
        return json_response(502, [
            'error' => 'internal sqlite update failed',
            'runtime' => 'php',
            'forwarded_to' => $internalPath,
        ]);
    }

    $status = parse_http_status($http_response_header ?? []);
    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        return json_response(502, [
            'error' => 'invalid internal response',
            'runtime' => 'php',
            'forwarded_to' => $internalPath,
            'raw' => $raw,
        ]);
    }

    if ($status < 200 || $status >= 300) {
        return json_response($status, [
            'runtime' => 'php',
            'route' => 'PUT /items/:id',
            'forwarded_to' => $internalPath,
            'error' => $decoded['error'] ?? 'update failed',
            'details' => $decoded,
        ]);
    }

    return json_response(200, [
        'runtime' => 'php',
        'route' => 'PUT /items/:id',
        'forwarded_to' => $internalPath,
        'db_kind' => 'sqlite',
        'item' => $decoded['item'] ?? null,
        'count' => $decoded['count'] ?? null,
        'db_file' => $decoded['db_file'] ?? null,
    ]);
}
