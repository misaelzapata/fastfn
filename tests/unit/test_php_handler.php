<?php

declare(strict_types=1);

$root = dirname(__DIR__, 2);
$handlerPath = $root . '/examples/functions/php/php_profile/app.php';

if (!is_file($handlerPath)) {
    fwrite(STDERR, "missing handler: $handlerPath\n");
    exit(1);
}

require $handlerPath;
if (!function_exists('handler')) {
    fwrite(STDERR, "handler function not found\n");
    exit(1);
}

$resp = handler([
    'query' => ['name' => 'UnitPHP'],
    'env' => ['PHP_GREETING' => 'php'],
]);

if (!is_array($resp)) {
    fwrite(STDERR, "response must be array\n");
    exit(1);
}
if (($resp['status'] ?? null) !== 200) {
    fwrite(STDERR, "status must be 200\n");
    exit(1);
}
if (!is_array($resp['headers'] ?? null)) {
    fwrite(STDERR, "headers must be array\n");
    exit(1);
}
if (!is_string($resp['body'] ?? null)) {
    fwrite(STDERR, "body must be string\n");
    exit(1);
}

$body = json_decode($resp['body'], true);
if (!is_array($body)) {
    fwrite(STDERR, "body must be valid json\n");
    exit(1);
}
if (($body['runtime'] ?? null) !== 'php') {
    fwrite(STDERR, "runtime mismatch\n");
    exit(1);
}
if (($body['hello'] ?? null) !== 'php-UnitPHP') {
    fwrite(STDERR, "hello mismatch\n");
    exit(1);
}

echo "php unit tests passed\n";
