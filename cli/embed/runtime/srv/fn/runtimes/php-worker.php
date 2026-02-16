<?php

declare(strict_types=1);

function emit_error(string $message, int $status = 500): void
{
    echo json_encode([
        'status' => $status,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode(['error' => $message], JSON_UNESCAPED_SLASHES),
    ], JSON_UNESCAPED_SLASHES);
}

function current_status_code(): int
{
    $status = http_response_code();
    if (!is_int($status) || $status < 100 || $status > 599) {
        return 200;
    }
    return $status;
}

function runtime_headers(): array
{
    $out = [];
    foreach (headers_list() as $raw) {
        if (!is_string($raw)) {
            continue;
        }
        $parts = explode(':', $raw, 2);
        if (count($parts) !== 2) {
            continue;
        }
        $name = trim($parts[0]);
        if ($name === '') {
            continue;
        }
        $value = trim($parts[1]);
        $out[$name] = $value;
    }
    return $out;
}

function read_script_status(): ?int
{
    if (!array_key_exists('FASTFN_STATUS', $GLOBALS)) {
        return null;
    }
    $raw = $GLOBALS['FASTFN_STATUS'];
    if (!is_int($raw) || $raw < 100 || $raw > 599) {
        return null;
    }
    return $raw;
}

function read_script_headers(): array
{
    if (!array_key_exists('FASTFN_HEADERS', $GLOBALS)) {
        return [];
    }
    $raw = $GLOBALS['FASTFN_HEADERS'];
    if (!is_array($raw)) {
        return [];
    }
    $out = [];
    foreach ($raw as $k => $v) {
        if (!is_string($k) || trim($k) === '') {
            continue;
        }
        if (is_array($v) || is_object($v)) {
            continue;
        }
        $out[$k] = (string) $v;
    }
    return $out;
}

function has_header(array $headers, string $name): bool
{
    foreach ($headers as $key => $_value) {
        if (strcasecmp((string) $key, $name) === 0) {
            return true;
        }
    }
    return false;
}

function header_value(array $headers, string $name): string
{
    foreach ($headers as $key => $value) {
        if (strcasecmp((string) $key, $name) === 0) {
            return (string) $value;
        }
    }
    return '';
}

function with_default_header(array $headers, string $name, string $value): array
{
    if (!has_header($headers, $name)) {
        $headers[$name] = $value;
    }
    return $headers;
}

function looks_like_html(string $body): bool
{
    $trimmed = strtolower(trim($body));
    return str_starts_with($trimmed, '<!doctype html')
        || str_starts_with($trimmed, '<html')
        || str_contains($trimmed, '<body')
        || str_contains($trimmed, '</html>');
}

function expects_binary_content_type(array $headers): bool
{
    $contentType = strtolower(trim(header_value($headers, 'Content-Type')));
    if ($contentType === '') {
        return false;
    }
    if (str_starts_with($contentType, 'text/')) {
        return false;
    }
    if (str_contains($contentType, 'json')
        || str_contains($contentType, 'xml')
        || str_contains($contentType, 'javascript')
        || str_contains($contentType, 'x-www-form-urlencoded')) {
        return false;
    }
    return true;
}

function is_csv_content_type(array $headers): bool
{
    return str_contains(strtolower(header_value($headers, 'Content-Type')), 'text/csv');
}

function looks_binary_string(string $body): bool
{
    if ($body === '') {
        return false;
    }
    if (str_contains($body, "\0")) {
        return true;
    }
    $sample = substr($body, 0, 4096);
    return @preg_match('//u', $sample) !== 1;
}

function has_contract_shape(array $resp): bool
{
    return array_key_exists('status', $resp)
        || array_key_exists('statusCode', $resp)
        || array_key_exists('headers', $resp)
        || array_key_exists('body', $resp)
        || array_key_exists('is_base64', $resp)
        || array_key_exists('isBase64Encoded', $resp)
        || array_key_exists('body_base64', $resp);
}

function csv_escape_cell(mixed $value): string
{
    if ($value === null) {
        $s = '';
    } elseif (is_array($value) || is_object($value)) {
        $s = json_encode($value, JSON_UNESCAPED_SLASHES);
        if (!is_string($s)) {
            $s = '';
        }
    } else {
        $s = (string) $value;
    }

    $s = str_replace('"', '""', $s);
    if (str_contains($s, ',') || str_contains($s, "\n") || str_contains($s, "\r") || str_contains($s, '"')) {
        return '"' . $s . '"';
    }
    return $s;
}

function csv_line(array $row): string
{
    $cells = [];
    foreach ($row as $cell) {
        $cells[] = csv_escape_cell($cell);
    }
    return implode(',', $cells);
}

function to_csv(mixed $value): string
{
    if (is_array($value)) {
        if ($value === []) {
            return '';
        }

        $first = reset($value);
        if (is_array($first) && array_is_list($first)) {
            $lines = [];
            foreach ($value as $row) {
                $lines[] = csv_line(is_array($row) ? $row : [$row]);
            }
            return implode("\n", $lines);
        }

        if (is_array($first) && !array_is_list($first)) {
            $keys = array_keys($first);
            $lines = [csv_line($keys)];
            foreach ($value as $row) {
                if (is_array($row)) {
                    $line = [];
                    foreach ($keys as $key) {
                        $line[] = $row[$key] ?? null;
                    }
                    $lines[] = csv_line($line);
                } else {
                    $lines[] = csv_line([$row]);
                }
            }
            return implode("\n", $lines);
        }

        if (!array_is_list($value)) {
            $keys = array_keys($value);
            return csv_line($keys) . "\n" . csv_line(array_values($value));
        }

        $lines = [];
        foreach ($value as $item) {
            $lines[] = csv_line([$item]);
        }
        return implode("\n", $lines);
    }

    if (is_object($value)) {
        $arr = (array) $value;
        if ($arr === []) {
            return '';
        }
        return csv_line(array_keys($arr)) . "\n" . csv_line(array_values($arr));
    }

    return csv_line([$value]);
}

function normalize_magic_response(mixed $value, ?int $status = null, ?array $headers = null): array
{
    $resolvedStatus = $status;
    if (!is_int($resolvedStatus) || $resolvedStatus < 100 || $resolvedStatus > 599) {
        $resolvedStatus = current_status_code();
    }
    $resolvedHeaders = is_array($headers) ? $headers : runtime_headers();

    if ($value === null) {
        return [
            'status' => $resolvedStatus,
            'headers' => $resolvedHeaders,
            'body' => '',
        ];
    }

    if (is_array($value) || is_object($value)) {
        if (is_csv_content_type($resolvedHeaders)) {
            return [
                'status' => $resolvedStatus,
                'headers' => with_default_header($resolvedHeaders, 'Content-Type', 'text/csv; charset=utf-8'),
                'body' => to_csv($value),
            ];
        }
        $encoded = json_encode($value, JSON_UNESCAPED_SLASHES);
        if (!is_string($encoded)) {
            $encoded = '{}';
        }
        return [
            'status' => $resolvedStatus,
            'headers' => with_default_header($resolvedHeaders, 'Content-Type', 'application/json'),
            'body' => $encoded,
        ];
    }

    $body = is_string($value) ? $value : (string) $value;
    if ($body === '') {
        return [
            'status' => $resolvedStatus,
            'headers' => $resolvedHeaders,
            'body' => '',
        ];
    }

    if (expects_binary_content_type($resolvedHeaders) || looks_binary_string($body)) {
        return [
            'status' => $resolvedStatus,
            'headers' => with_default_header($resolvedHeaders, 'Content-Type', 'application/octet-stream'),
            'is_base64' => true,
            'body_base64' => base64_encode($body),
        ];
    }

    $inferredType = looks_like_html($body) ? 'text/html; charset=utf-8' : 'text/plain; charset=utf-8';
    return [
        'status' => $resolvedStatus,
        'headers' => with_default_header($resolvedHeaders, 'Content-Type', $inferredType),
        'body' => $body,
    ];
}

function normalize_explicit_response(array $resp, array $runtimeHeaders): array
{
    if (array_key_exists('statusCode', $resp) && !array_key_exists('status', $resp)) {
        $resp['status'] = $resp['statusCode'];
    }
    $status = $resp['status'] ?? 200;
    if (!is_int($status) || $status < 100 || $status > 599) {
        throw new RuntimeException('status must be a valid HTTP code');
    }

    $declaredHeaders = $resp['headers'] ?? [];
    if (!is_array($declaredHeaders)) {
        throw new RuntimeException('headers must be an object');
    }
    $headers = array_merge($runtimeHeaders, $declaredHeaders);

    if (array_key_exists('isBase64Encoded', $resp) && !array_key_exists('is_base64', $resp)) {
        $resp['is_base64'] = $resp['isBase64Encoded'] === true;
    }
    if (!empty($resp['is_base64'])) {
        if (array_key_exists('body_base64', $resp)) {
            $b64 = $resp['body_base64'];
        } elseif (array_key_exists('body', $resp)) {
            $b64 = $resp['body'];
        } else {
            $b64 = '';
        }
        if (!is_string($b64) || $b64 === '') {
            throw new RuntimeException('body_base64 must be a non-empty string when is_base64=true');
        }
        return [
            'status' => $status,
            'headers' => $headers,
            'is_base64' => true,
            'body_base64' => $b64,
        ];
    }

    $body = $resp['body'] ?? '';
    if ($body === null) {
        $body = '';
    }
    if (is_array($body) || is_object($body)) {
        if (is_csv_content_type($headers)) {
            $body = to_csv($body);
            $headers = with_default_header($headers, 'Content-Type', 'text/csv; charset=utf-8');
        } else {
            $encoded = json_encode($body, JSON_UNESCAPED_SLASHES);
            $body = is_string($encoded) ? $encoded : '';
            $headers = with_default_header($headers, 'Content-Type', 'application/json');
        }
    } elseif (!is_string($body)) {
        $body = (string) $body;
    }

    if ($body !== '' && (expects_binary_content_type($headers) || looks_binary_string($body))) {
        return [
            'status' => $status,
            'headers' => with_default_header($headers, 'Content-Type', 'application/octet-stream'),
            'is_base64' => true,
            'body_base64' => base64_encode($body),
        ];
    }

    return [
        'status' => $status,
        'headers' => $headers,
        'body' => $body,
    ];
}

set_error_handler(static function (int $severity, string $message, string $file, int $line): bool {
    throw new ErrorException($message, 0, $severity, $file, $line);
});

$handlerPath = $argv[1] ?? '';
if (!is_string($handlerPath) || $handlerPath === '' || !is_file($handlerPath)) {
    emit_error('unknown function', 404);
    exit(0);
}

$raw = stream_get_contents(STDIN);
$event = json_decode(is_string($raw) ? $raw : '', true);
if (!is_array($event)) {
    $event = [];
}

try {
    header_remove();
    http_response_code(200);
    ob_start();

    require $handlerPath;

    $hasHandler = function_exists('handler');
    $resp = null;
    if ($hasHandler) {
        $resp = handler($event);
    }

    $capturedOutput = (string) ob_get_clean();
    $runtimeHeaders = array_merge(runtime_headers(), read_script_headers());
    $runtimeStatus = read_script_status() ?? current_status_code();

    if ($hasHandler) {
        if (is_array($resp) && has_contract_shape($resp)) {
            $normalized = normalize_explicit_response($resp, $runtimeHeaders);
            if (empty($normalized['is_base64']) && $capturedOutput !== '') {
                $body = $normalized['body'] ?? '';
                if (!is_string($body) || $body === '') {
                    $normalized = normalize_magic_response(
                        $capturedOutput,
                        (int) ($normalized['status'] ?? 200),
                        $normalized['headers'] ?? $runtimeHeaders
                    );
                }
            }
        } else {
            $magicValue = $resp;
            if (($magicValue === null || $magicValue === '') && $capturedOutput !== '') {
                $magicValue = $capturedOutput;
            } elseif (is_string($magicValue) && $capturedOutput !== '') {
                $magicValue = $capturedOutput . $magicValue;
            }
            $normalized = normalize_magic_response($magicValue, $runtimeStatus, $runtimeHeaders);
        }
    } else {
        $normalized = normalize_magic_response($capturedOutput, $runtimeStatus, $runtimeHeaders);
    }

    echo json_encode($normalized, JSON_UNESCAPED_SLASHES);
} catch (Throwable $e) {
    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    emit_error($e->getMessage(), 500);
}
