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
    require $handlerPath;

    if (!function_exists('handler')) {
        throw new RuntimeException('handler(event) is required');
    }

    $resp = handler($event);
    if (!is_array($resp)) {
        throw new RuntimeException('handler response must be an object');
    }

    if (array_key_exists('statusCode', $resp) && !array_key_exists('status', $resp)) {
        $resp['status'] = $resp['statusCode'];
    }
    if (!array_key_exists('status', $resp)) {
        $resp['status'] = 200;
    }

    if (!array_key_exists('headers', $resp) || !is_array($resp['headers'])) {
        $resp['headers'] = [];
    }

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
        $resp = [
            'status' => $resp['status'],
            'headers' => $resp['headers'],
            'is_base64' => true,
            'body_base64' => $b64,
        ];
    } else {
        $body = $resp['body'] ?? '';
        if (!is_string($body)) {
            if (is_scalar($body) || $body === null) {
                $body = (string) $body;
            } else {
                $body = json_encode($body, JSON_UNESCAPED_SLASHES);
                if (!is_string($body)) {
                    $body = '';
                }
            }
        }
        $resp = [
            'status' => $resp['status'],
            'headers' => $resp['headers'],
            'body' => $body,
        ];
    }

    echo json_encode($resp, JSON_UNESCAPED_SLASHES);
} catch (Throwable $e) {
    emit_error($e->getMessage(), 500);
}
