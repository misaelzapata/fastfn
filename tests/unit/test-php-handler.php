<?php

declare(strict_types=1);

$root = dirname(__DIR__, 2);
$handlerPath = $root . '/examples/functions/php/php-profile/handler.php';
$workerPath = $root . '/srv/fn/runtimes/php-worker.php';
$persistentHelloPath = $root . '/tests/fixtures/local-dev-samples-migrated/php-hello/handler.php';
$rawExportPath = $root . '/examples/functions/next-style/php/get.export.php';

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

function assert_contains(string $haystack, string $needle, string $msg): void
{
    if (strpos($haystack, $needle) === false) {
        fail_test($msg . ' missing=' . var_export($needle, true) . ' in=' . var_export($haystack, true));
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

function open_worker_process(string $workerPath, string $targetHandlerPath, array $env = [])
{
    $cmd = ['php', $workerPath, $targetHandlerPath];
    $descriptors = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];
    $procEnv = null;
    if ($env !== []) {
        $procEnv = array_merge(
            ['PATH' => getenv('PATH') ?: ''],
            array_map(static fn ($value): string => (string) $value, $_ENV),
            $env
        );
    }
    $proc = proc_open($cmd, $descriptors, $pipes, null, $procEnv);
    if (!is_resource($proc)) {
        fail_test('failed to start php worker');
    }
    return [$proc, $pipes];
}

function run_worker_once(string $workerPath, string $targetHandlerPath, array $event): array
{
    [$proc, $pipes] = open_worker_process($workerPath, $targetHandlerPath);
    fwrite($pipes[0], json_encode($event, JSON_UNESCAPED_SLASHES));
    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    $exit = proc_close($proc);
    assert_same($exit, 0, 'php worker one-shot exit mismatch stderr=' . trim((string) $stderr));
    $resp = json_decode((string) $stdout, true);
    assert_true(is_array($resp), 'php worker one-shot must return json stdout=' . (string) $stdout . ' stderr=' . (string) $stderr);
    return $resp;
}

function write_worker_frame($stream, array $payload): void
{
    $json = json_encode($payload, JSON_UNESCAPED_SLASHES);
    if (!is_string($json)) {
        fail_test('failed to encode worker frame');
    }
    fwrite($stream, pack('N', strlen($json)));
    fwrite($stream, $json);
    fflush($stream);
}

function read_worker_frame($stream): array
{
    $header = stream_get_contents($stream, 4);
    assert_true(is_string($header) && strlen($header) === 4, 'missing worker frame header');
    $unpacked = unpack('Nlength', $header);
    assert_true(is_array($unpacked) && isset($unpacked['length']), 'invalid worker frame header');
    $length = (int) $unpacked['length'];
    $payload = stream_get_contents($stream, $length);
    assert_true(is_string($payload) && strlen($payload) === $length, 'incomplete worker frame payload');
    $decoded = json_decode($payload, true);
    assert_true(is_array($decoded), 'worker frame payload must be json');
    return $decoded;
}

function test_worker_regressions(string $workerPath, string $persistentHelloPath, string $rawExportPath): void
{
    $helloResp = run_worker_once($workerPath, $persistentHelloPath, []);
    $helloBody = assert_response_contract($helloResp);
    assert_same($helloBody['runtime'] ?? null, 'php', 'worker hello runtime mismatch');
    assert_same($helloBody['message'] ?? null, 'Hello from PHP!', 'worker hello message mismatch');

    $rawResp = run_worker_once($workerPath, $rawExportPath, []);
    assert_same($rawResp['status'] ?? null, 200, 'raw export status mismatch');
    assert_true(is_array($rawResp['headers'] ?? null), 'raw export headers must be array');
    assert_contains((string) ($rawResp['headers']['Content-Type'] ?? ''), 'text/csv', 'raw export content type mismatch');
    assert_contains((string) ($rawResp['headers']['Content-Disposition'] ?? ''), 'php-export.csv', 'raw export disposition mismatch');
    assert_contains((string) ($rawResp['body'] ?? ''), "id,source\n10,php-mod-style", 'raw export body mismatch');

    [$proc, $pipes] = open_worker_process(
        $workerPath,
        $persistentHelloPath,
        ['_FASTFN_WORKER_MODE' => 'persistent']
    );
    try {
        write_worker_frame($pipes[0], []);
        $first = read_worker_frame($pipes[1]);
        $firstBody = assert_response_contract($first);
        assert_same($firstBody['runtime'] ?? null, 'php', 'persistent worker first runtime mismatch');

        write_worker_frame($pipes[0], []);
        $second = read_worker_frame($pipes[1]);
        $secondBody = assert_response_contract($second);
        assert_same($secondBody['runtime'] ?? null, 'php', 'persistent worker second runtime mismatch');
    } finally {
        fclose($pipes[0]);
        $stderr = stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $exit = proc_close($proc);
        assert_same($exit, 0, 'php worker persistent exit mismatch stderr=' . trim((string) $stderr));
    }
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
assert_same($body['function'] ?? null, 'php-profile', 'function mismatch');
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

test_worker_regressions($workerPath, $persistentHelloPath, $rawExportPath);

echo "php unit tests passed\n";
