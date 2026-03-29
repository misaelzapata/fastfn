<?php

declare(strict_types=1);

function emit_error(string $message, int $status = 500): void
{
    echo json_encode(error_response($message, $status), JSON_UNESCAPED_SLASHES);
}

function error_response(string $message, int $status = 500): array
{
    return [
        'status' => $status,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode(['error' => $message], JSON_UNESCAPED_SLASHES),
    ];
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
    return parse_script_status_value($GLOBALS['FASTFN_STATUS'] ?? null);
}

function read_script_headers(): array
{
    return parse_script_headers_value($GLOBALS['FASTFN_HEADERS'] ?? null);
}

function parse_script_status_value(mixed $raw): ?int
{
    if (!is_int($raw) || $raw < 100 || $raw > 599) {
        return null;
    }
    return $raw;
}

function parse_script_headers_value(mixed $raw): array
{
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

function frame_read($stream): ?string
{
    $header = '';
    while (strlen($header) < 4) {
        $chunk = fread($stream, 4 - strlen($header));
        if ($chunk === false || $chunk === '') {
            return null;
        }
        $header .= $chunk;
    }

    $unpacked = unpack('Nlength', $header);
    $length = is_array($unpacked) && array_key_exists('length', $unpacked) ? (int) $unpacked['length'] : 0;
    if ($length <= 0) {
        return null;
    }

    $payload = '';
    while (strlen($payload) < $length) {
        $chunk = fread($stream, $length - strlen($payload));
        if ($chunk === false || $chunk === '') {
            return null;
        }
        $payload .= $chunk;
    }
    return $payload;
}

function frame_write($stream, array $payload): void
{
    $encoded = json_encode($payload, JSON_UNESCAPED_SLASHES);
    if (!is_string($encoded)) {
        $encoded = json_encode(error_response('failed to encode runtime response', 500), JSON_UNESCAPED_SLASHES);
        if (!is_string($encoded)) {
            $encoded = '{"status":500,"headers":{"Content-Type":"application/json"},"body":"{\"error\":\"failed to encode runtime response\"}"}';
        }
    }
    fwrite($stream, pack('N', strlen($encoded)) . $encoded);
    fflush($stream);
}

function restore_runtime_env(array &$appliedEnv): void
{
    foreach ($appliedEnv as $key => $meta) {
        if (!is_string($key) || !is_array($meta)) {
            continue;
        }
        $present = ($meta['present'] ?? false) === true;
        $value = isset($meta['value']) ? (string) $meta['value'] : '';
        if ($present) {
            putenv($key . '=' . $value);
            $_ENV[$key] = $value;
            $_SERVER[$key] = $value;
        } else {
            putenv($key);
            unset($_ENV[$key], $_SERVER[$key]);
        }
    }
    $appliedEnv = [];
}

function apply_runtime_env(array $rawEnv, array &$appliedEnv): void
{
    restore_runtime_env($appliedEnv);
    foreach ($rawEnv as $key => $value) {
        if (!is_string($key) || trim($key) === '') {
            continue;
        }
        if (is_array($value) || is_object($value)) {
            continue;
        }
        $current = getenv($key);
        $appliedEnv[$key] = [
            'present' => $current !== false,
            'value' => $current !== false ? (string) $current : '',
        ];
        $stringValue = (string) $value;
        putenv($key . '=' . $stringValue);
        $_ENV[$key] = $stringValue;
        $_SERVER[$key] = $stringValue;
    }
}

function reset_runtime_state(): void
{
    header_remove();
    http_response_code(200);
    unset($GLOBALS['FASTFN_STATUS'], $GLOBALS['FASTFN_HEADERS']);
}

function find_handler_function(array $newFunctions): ?string
{
    for ($i = count($newFunctions) - 1; $i >= 0; $i--) {
        $candidate = $newFunctions[$i];
        if (!is_string($candidate) || $candidate === '') {
            continue;
        }
        $parts = explode('\\', $candidate);
        $baseName = strtolower((string) end($parts));
        if ($baseName === 'handler' && function_exists($candidate)) {
            return $candidate;
        }
    }

    if (function_exists('handler')) {
        return 'handler';
    }

    return null;
}

function load_handler_artifacts(string $handlerPath): array
{
    $beforeFunctions = [];
    foreach (get_defined_functions()['user'] as $name) {
        $beforeFunctions[strtolower($name)] = true;
    }

    $loaded = (function () use ($handlerPath): array {
        $FASTFN_STATUS = null;
        $FASTFN_HEADERS = null;
        ob_start();
        require $handlerPath;
        return [
            'captured_output' => (string) ob_get_clean(),
            'scoped_status' => $FASTFN_STATUS,
            'scoped_headers' => $FASTFN_HEADERS,
        ];
    })();

    $newFunctions = [];
    foreach (get_defined_functions()['user'] as $name) {
        if (!isset($beforeFunctions[strtolower($name)])) {
            $newFunctions[] = $name;
        }
    }

    return [
        'captured_output' => is_string($loaded['captured_output'] ?? null) ? $loaded['captured_output'] : '',
        'runtime_status' => parse_script_status_value($loaded['scoped_status'] ?? null) ?? read_script_status() ?? current_status_code(),
        'runtime_headers' => array_merge(
            runtime_headers(),
            parse_script_headers_value($loaded['scoped_headers'] ?? null),
            read_script_headers()
        ),
        'handler_name' => find_handler_function($newFunctions),
    ];
}

function invoke_handler_callable(
    string $handlerName,
    array $event,
    string $capturedOutput,
    array $baseHeaders,
    int $baseStatus
): array {
    $params = isset($event['params']) && is_array($event['params']) ? $event['params'] : [];
    ob_start();
    $rf = new ReflectionFunction($handlerName);
    $resp = $rf->getNumberOfParameters() > 1 ? $handlerName($event, $params) : $handlerName($event);
    $handlerOutput = (string) ob_get_clean();
    $capturedOutput .= $handlerOutput;

    $runtimeHeaders = array_merge($baseHeaders, runtime_headers(), read_script_headers());
    $runtimeStatus = read_script_status() ?? current_status_code();
    if (!is_int($runtimeStatus) || $runtimeStatus < 100 || $runtimeStatus > 599) {
        $runtimeStatus = $baseStatus;
    }

    if (is_array($resp) && has_contract_shape($resp)) {
        $normalized = normalize_explicit_response($resp, $runtimeHeaders);
        if (empty($normalized['is_base64']) && $capturedOutput !== '') {
            $body = $normalized['body'] ?? '';
            if (!is_string($body) || $body === '') {
                $normalized = normalize_magic_response(
                    $capturedOutput,
                    (int) ($normalized['status'] ?? $runtimeStatus),
                    $normalized['headers'] ?? $runtimeHeaders
                );
            }
        }
        return $normalized;
    }

    $magicValue = $resp;
    if (($magicValue === null || $magicValue === '') && $capturedOutput !== '') {
        $magicValue = $capturedOutput;
    } elseif (is_string($magicValue) && $capturedOutput !== '') {
        $magicValue = $capturedOutput . $magicValue;
    }
    return normalize_magic_response($magicValue, $runtimeStatus, $runtimeHeaders);
}

function invoke_handler_file(string $handlerPath, array $event, int &$requestCounter): array
{
    static $cachedHandlerPath = null;
    static $cachedHandlerName = null;

    $requestCounter++;
    reset_runtime_state();

    if (
        $cachedHandlerPath === $handlerPath
        && is_string($cachedHandlerName)
        && $cachedHandlerName !== ''
        && function_exists($cachedHandlerName)
    ) {
        return invoke_handler_callable($cachedHandlerName, $event, '', [], 200);
    }

    $loaded = load_handler_artifacts($handlerPath);
    $handlerName = $loaded['handler_name'] ?? null;
    if (is_string($handlerName) && $handlerName !== '') {
        $cachedHandlerPath = $handlerPath;
        $cachedHandlerName = $handlerName;
        return invoke_handler_callable(
            $handlerName,
            $event,
            is_string($loaded['captured_output'] ?? null) ? $loaded['captured_output'] : '',
            is_array($loaded['runtime_headers'] ?? null) ? $loaded['runtime_headers'] : [],
            is_int($loaded['runtime_status'] ?? null) ? $loaded['runtime_status'] : 200
        );
    }

    return normalize_magic_response(
        is_string($loaded['captured_output'] ?? null) ? $loaded['captured_output'] : '',
        is_int($loaded['runtime_status'] ?? null) ? $loaded['runtime_status'] : 200,
        is_array($loaded['runtime_headers'] ?? null) ? $loaded['runtime_headers'] : []
    );
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

if (getenv('_FASTFN_WORKER_MODE') === 'persistent') {
    $requestCounter = 0;
    $appliedEnv = [];
    while (true) {
        $payload = frame_read(STDIN);
        if (!is_string($payload) || $payload === '') {
            break;
        }
        $event = json_decode($payload, true);
        if (!is_array($event)) {
            $event = [];
        }
        try {
            $rawEnv = isset($event['env']) && is_array($event['env']) ? $event['env'] : [];
            apply_runtime_env($rawEnv, $appliedEnv);
            $normalized = invoke_handler_file($handlerPath, $event, $requestCounter);
        } catch (Throwable $e) {
            while (ob_get_level() > 0) {
                ob_end_clean();
            }
            $normalized = error_response($e->getMessage(), 500);
        }
        frame_write(STDOUT, $normalized);
    }
    restore_runtime_env($appliedEnv);
    exit(0);
}

$raw = stream_get_contents(STDIN);
$event = json_decode(is_string($raw) ? $raw : '', true);
if (!is_array($event)) {
    $event = [];
}

try {
    $requestCounter = 0;
    $appliedEnv = [];
    $rawEnv = isset($event['env']) && is_array($event['env']) ? $event['env'] : [];
    apply_runtime_env($rawEnv, $appliedEnv);
    $normalized = invoke_handler_file($handlerPath, $event, $requestCounter);
    restore_runtime_env($appliedEnv);
    echo json_encode($normalized, JSON_UNESCAPED_SLASHES);
} catch (Throwable $e) {
    while (ob_get_level() > 0) {
        ob_end_clean();
    }
    emit_error($e->getMessage(), 500);
}
