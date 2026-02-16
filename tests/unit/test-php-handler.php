<?php

declare(strict_types=1);

$root = dirname(__DIR__, 2);
$handlerPath = $root . '/examples/functions/php/php_profile/app.php';

function fail_test(string $msg): void
{
    fwrite(STDERR, $msg . "\n");
    exit(1);
}

function assert_true(bool $ok, string $msg): void
{
    if (!$ok) {
        fail_test($msg);
    }
}

function assert_same($actual, $expected, string $msg): void
{
    if ($actual !== $expected) {
        fail_test($msg . ' expected=' . var_export($expected, true) . ' actual=' . var_export($actual, true));
    }
}

function assert_response_contract(array $resp): array
{
    assert_true(is_array($resp), 'response must be array');
    assert_same($resp['status'] ?? null, 200, 'status must be 200');
    assert_true(is_array($resp['headers'] ?? null), 'headers must be array');
    assert_same($resp['headers']['Content-Type'] ?? null, 'application/json', 'content type mismatch');
    assert_true(is_string($resp['body'] ?? null), 'body must be string');
    $body = json_decode($resp['body'], true);
    assert_true(is_array($body), 'body must be valid json');
    return $body;
}

if (!is_file($handlerPath)) {
    fail_test("missing handler: $handlerPath");
}

require $handlerPath;
if (!function_exists('handler')) {
    fail_test('handler function not found');
}

$resp = handler([
    'query' => ['name' => 'UnitPHP'],
    'env' => ['PHP_GREETING' => 'php'],
]);
$body = assert_response_contract($resp);
assert_same($body['runtime'] ?? null, 'php', 'runtime mismatch');
assert_same($body['function'] ?? null, 'php_profile', 'function mismatch');
assert_same($body['hello'] ?? null, 'php-UnitPHP', 'hello mismatch custom name');

$respDefault = handler([]);
$bodyDefault = assert_response_contract($respDefault);
assert_same($bodyDefault['hello'] ?? null, 'php-world', 'default fallback mismatch');

$respCustomPrefix = handler([
    'query' => ['name' => 'EnvName'],
    'env' => ['PHP_GREETING' => 'custom'],
]);
$bodyCustomPrefix = assert_response_contract($respCustomPrefix);
assert_same($bodyCustomPrefix['hello'] ?? null, 'custom-EnvName', 'custom env prefix mismatch');

echo "php unit tests passed\n";
