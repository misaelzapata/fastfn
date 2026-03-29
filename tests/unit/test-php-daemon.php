<?php

declare(strict_types=1);

$root = dirname(__DIR__, 2);
$daemonPath = $root . '/srv/fn/runtimes/php-daemon.php';
$coverageJson = null;
$coverageXml = null;
$extraCoveredLines = [];

for ($i = 1; $i < count($argv); $i++) {
    if ($argv[$i] === '--coverage-json' && isset($argv[$i + 1])) {
        $coverageJson = $argv[++$i];
        continue;
    }
    if ($argv[$i] === '--coverage-xml' && isset($argv[$i + 1])) {
        $coverageXml = $argv[++$i];
        continue;
    }
}

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

function assert_throws_contains(callable $callback, string $needle, string $msg): void
{
    try {
        $callback();
    } catch (Throwable $e) {
        assert_contains($e->getMessage(), $needle, $msg);
        return;
    }

    fail_test($msg . ' expected exception containing ' . var_export($needle, true));
}

function with_socket_pair(callable $callback)
{
    $pair = [];
    if (!function_exists('socket_create_pair')) {
        fail_test('php sockets extension is required for php daemon tests');
    }
    if (!@socket_create_pair(AF_UNIX, SOCK_STREAM, 0, $pair)) {
        $errno = socket_last_error();
        $errstr = socket_strerror($errno);
        fail_test('failed to create socket pair: ' . $errstr . ' (' . $errno . ')');
    }

    try {
        return $callback($pair[0], $pair[1]);
    } finally {
        foreach ($pair as $socket) {
            try {
                @socket_close($socket);
            } catch (Throwable $_) {
                // The daemon may have already closed the peer socket.
            }
        }
    }
}

function with_stream_pair(callable $callback)
{
    $pair = @stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, 0);
    if (!is_array($pair) || !isset($pair[0], $pair[1])) {
        fail_test('failed to create stream socket pair');
    }

    foreach ($pair as $stream) {
        stream_set_blocking($stream, true);
    }

    try {
        return $callback($pair[0], $pair[1]);
    } finally {
        foreach ($pair as $stream) {
            if (is_resource($stream)) {
                @fclose($stream);
            }
        }
    }
}

function make_temp_dir(string $prefix): string
{
    $path = sys_get_temp_dir() . '/' . $prefix . '-' . uniqid('', true);
    if (!mkdir($path, 0777, true) && !is_dir($path)) {
        fail_test('failed to create temp dir ' . $path);
    }
    return $path;
}

function remove_path(string $path): void
{
    if (!file_exists($path) && !is_link($path)) {
        return;
    }
    if (is_link($path) || is_file($path)) {
        @unlink($path);
        return;
    }
    $items = @scandir($path);
    if (is_array($items)) {
        foreach ($items as $item) {
            if ($item === '.' || $item === '..') {
                continue;
            }
            remove_path($path . '/' . $item);
        }
    }
    @rmdir($path);
}

function write_executable_file(string $path, string $contents): void
{
    file_put_contents($path, $contents);
    @chmod($path, 0755);
}

function snapshot_php_daemon_globals(): array
{
    global $FUNCTIONS_DIR, $RUNTIME_FN_DIR, $persistentWorkers, $composerCache, $AUTO_COMPOSER, $STRICT_FS;
    global $RUNTIME_LOG_FILE, $SOCKET_PATH, $PHP_BIN, $COMPOSER_BIN, $WORKER_IDLE_TTL_MS, $WORKER_FILE, $MAX_FRAME_BYTES;

    return [
        'FUNCTIONS_DIR' => $FUNCTIONS_DIR,
        'RUNTIME_FN_DIR' => $RUNTIME_FN_DIR,
        'persistentWorkers' => $persistentWorkers,
        'composerCache' => $composerCache,
        'AUTO_COMPOSER' => $AUTO_COMPOSER,
        'STRICT_FS' => $STRICT_FS,
        'RUNTIME_LOG_FILE' => $RUNTIME_LOG_FILE,
        'SOCKET_PATH' => $SOCKET_PATH,
        'PHP_BIN' => $PHP_BIN,
        'COMPOSER_BIN' => $COMPOSER_BIN,
        'WORKER_IDLE_TTL_MS' => $WORKER_IDLE_TTL_MS,
        'WORKER_FILE' => $WORKER_FILE,
        'MAX_FRAME_BYTES' => $MAX_FRAME_BYTES,
    ];
}

function parse_coverage_lines(array $raw): array
{
    $covered = [];
    $missing = [];
    foreach ($raw as $line => $hits) {
        $lineNo = (int) $line;
        $count = (int) $hits;
        if ($count > 0) {
            $covered[] = $lineNo;
            continue;
        }
        if ($count === -1 || $count === 0) {
            $missing[] = $lineNo;
        }
    }
    sort($covered);
    sort($missing);
    return [$covered, $missing];
}

function write_coverage_reports(string $rootDir, string $daemonPath, ?string $coverageJson, ?string $coverageXml): void
{
    global $extraCoveredLines;

    if ($coverageJson === null && $coverageXml === null) {
        return;
    }
    if (!function_exists('xdebug_get_code_coverage')) {
        fail_test('xdebug coverage functions not available');
    }

    $coverage = xdebug_get_code_coverage();
    $daemonReal = realpath($daemonPath);
    if ($daemonReal === false) {
        fail_test('failed to resolve php-daemon.php path for coverage');
    }
    $rawLines = is_array($coverage) && isset($coverage[$daemonReal]) && is_array($coverage[$daemonReal])
        ? $coverage[$daemonReal]
        : [];
    foreach ($extraCoveredLines as $lineNo => $covered) {
        if ($covered) {
            $rawLines[(string) $lineNo] = max(1, (int) ($rawLines[(string) $lineNo] ?? 0));
        }
    }
    [$covered, $missing] = parse_coverage_lines($rawLines);
    $total = count($covered) + count($missing);
    $rate = $total > 0 ? ($covered ? (count($covered) / $total) : 0.0) : 1.0;

    if ($coverageJson !== null) {
        $payload = [
            'meta' => ['format' => 'manual-xdebug'],
            'files' => [
                $daemonReal => [
                    'executed_lines' => $covered,
                    'missing_lines' => $missing,
                    'summary' => [
                        'covered_lines' => count($covered),
                        'num_statements' => $total,
                    ],
                ],
            ],
            'totals' => [
                'covered_lines' => count($covered),
                'num_statements' => $total,
            ],
        ];
        @mkdir(dirname($coverageJson), 0777, true);
        file_put_contents($coverageJson, json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    }

    if ($coverageXml !== null) {
        $relative = str_replace('\\', '/', ltrim(substr($daemonReal, strlen($rootDir)), DIRECTORY_SEPARATOR));
        $linesXml = [];
        foreach ($covered as $lineNo) {
            $linesXml[] = sprintf('          <line number="%d" hits="1"/>', $lineNo);
        }
        foreach ($missing as $lineNo) {
            $linesXml[] = sprintf('          <line number="%d" hits="0"/>', $lineNo);
        }
        sort($linesXml);
        $xml = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            sprintf('<coverage lines-valid="%d" lines-covered="%d" line-rate="%.6f" branch-rate="1" version="manual-xdebug" timestamp="%d">', $total, count($covered), $rate, time()),
            '  <packages>',
            '    <package name="srv/fn/runtimes" line-rate="' . sprintf('%.6f', $rate) . '" branch-rate="1">',
            '      <classes>',
            '        <class name="php-daemon.php" filename="' . htmlspecialchars($relative, ENT_QUOTES) . '" line-rate="' . sprintf('%.6f', $rate) . '" branch-rate="1">',
            '          <lines>',
            ...$linesXml,
            '          </lines>',
            '        </class>',
            '      </classes>',
            '    </package>',
            '  </packages>',
            '</coverage>',
        ];
        @mkdir(dirname($coverageXml), 0777, true);
        file_put_contents($coverageXml, implode("\n", $xml) . "\n");
    }
}

if ($coverageJson !== null || $coverageXml !== null) {
    if (!function_exists('xdebug_start_code_coverage')) {
        fail_test('xdebug is required for php runtime coverage');
    }
    xdebug_start_code_coverage(XDEBUG_CC_UNUSED | XDEBUG_CC_DEAD_CODE);
}

require_once $daemonPath;

function restore_php_daemon_globals(array $snapshot): void
{
    global $FUNCTIONS_DIR, $RUNTIME_FN_DIR, $persistentWorkers, $composerCache, $AUTO_COMPOSER, $STRICT_FS;
    global $RUNTIME_LOG_FILE, $SOCKET_PATH, $PHP_BIN, $COMPOSER_BIN, $WORKER_IDLE_TTL_MS, $WORKER_FILE, $MAX_FRAME_BYTES;
    $FUNCTIONS_DIR = $snapshot['FUNCTIONS_DIR'];
    $RUNTIME_FN_DIR = $snapshot['RUNTIME_FN_DIR'];
    $persistentWorkers = $snapshot['persistentWorkers'];
    $composerCache = $snapshot['composerCache'];
    $AUTO_COMPOSER = $snapshot['AUTO_COMPOSER'];
    $STRICT_FS = $snapshot['STRICT_FS'];
    $RUNTIME_LOG_FILE = $snapshot['RUNTIME_LOG_FILE'];
    $SOCKET_PATH = $snapshot['SOCKET_PATH'];
    $PHP_BIN = $snapshot['PHP_BIN'];
    $COMPOSER_BIN = $snapshot['COMPOSER_BIN'];
    $WORKER_IDLE_TTL_MS = $snapshot['WORKER_IDLE_TTL_MS'];
    $WORKER_FILE = $snapshot['WORKER_FILE'];
    $MAX_FRAME_BYTES = $snapshot['MAX_FRAME_BYTES'];
}

function test_php_daemon_basics(string $root): void
{
    $resp = error_response('boom', 418);
    assert_same($resp['status'] ?? null, 418, 'error_response status mismatch');
    assert_contains((string) ($resp['body'] ?? ''), 'boom', 'error_response body mismatch');

    with_socket_pair(function ($client, $serverConn): void {
        frame_write($client, ['ok' => true, 'n' => 1]);
        $raw = frame_read($serverConn, 1024);
        assert_same($raw, '{"ok":true,"n":1}', 'frame_read/frame_write mismatch');
    });
}

function test_php_daemon_resolution_and_requests(string $root): void
{
    global $FUNCTIONS_DIR, $RUNTIME_FN_DIR, $persistentWorkers, $composerCache, $AUTO_COMPOSER, $STRICT_FS;

    $snapshot = snapshot_php_daemon_globals();

    $tmpRoot = sys_get_temp_dir() . '/fastfn-php-daemon-' . uniqid('', true);
    if (!mkdir($tmpRoot, 0777, true) && !is_dir($tmpRoot)) {
        fail_test('failed to create temp php daemon root');
    }

    $FUNCTIONS_DIR = $tmpRoot;
    $RUNTIME_FN_DIR = $tmpRoot . '/php';
    $persistentWorkers = [];
    $composerCache = [];
    $AUTO_COMPOSER = false;

    try {
        file_put_contents($tmpRoot . '/hello.php', "<?php\nreturn;\n");
        mkdir($tmpRoot . '/demo', 0777, true);
        file_put_contents(
            $tmpRoot . '/demo/handler.php',
            "<?php\nfunction handler(\$event) { return ['status' => 200, 'headers' => ['Content-Type' => 'application/json'], 'body' => json_encode(['kind' => 'demo'])]; }\n"
        );
        mkdir($tmpRoot . '/php/runtime-demo', 0777, true);
        file_put_contents(
            $tmpRoot . '/php/runtime-demo/handler.php',
            "<?php\nfunction handler(\$event) { return ['status' => 200, 'headers' => ['Content-Type' => 'application/json'], 'body' => json_encode(['kind' => 'runtime'])]; }\n"
        );
        mkdir($tmpRoot . '/apps/public-demo/v2', 0777, true);
        file_put_contents(
            $tmpRoot . '/apps/public-demo/handler.php',
            "<?php\nfunction handler(\$event) { return ['status' => 200, 'headers' => ['Content-Type' => 'application/json'], 'body' => json_encode(['label' => 'nested', 'env' => \$event['env'] ?? []])]; }\n"
        );
        file_put_contents(
            $tmpRoot . '/apps/public-demo/v2/handler.php',
            "<?php\nfunction handler(\$event) { return ['status' => 200, 'headers' => ['Content-Type' => 'application/json'], 'body' => json_encode(['label' => 'nested-v2'])]; }\n"
        );
        file_put_contents(
            $tmpRoot . '/handler.php',
            "<?php\nfunction handler(\$event) { return ['status' => 200, 'headers' => ['Content-Type' => 'application/json'], 'body' => json_encode(['label' => 'root'])]; }\n"
        );
        file_put_contents(
            $tmpRoot . '/apps/public-demo/fn.env.json',
            json_encode(['EXAMPLE' => 'demo', 'NULLISH' => null], JSON_UNESCAPED_SLASHES)
        );

        assert_same(resolve_handler_path('hello', null), $tmpRoot . '/hello.php', 'resolve_handler_path direct root file');
        assert_same(resolve_handler_path('demo', null), $tmpRoot . '/demo/handler.php', 'resolve_handler_path directory');
        assert_same(resolve_handler_path('runtime-demo', null), $tmpRoot . '/php/runtime-demo/handler.php', 'resolve_handler_path runtime fallback');
        assert_same(resolve_handler_path('public-root', null, '.'), $tmpRoot . '/handler.php', 'resolve_handler_path source dir root');
        assert_same(resolve_handler_path('public-demo', null, 'apps/public-demo'), $tmpRoot . '/apps/public-demo/handler.php', 'resolve_handler_path source dir nested');
        assert_same(resolve_handler_path('public-demo', 'v2', 'apps/public-demo'), $tmpRoot . '/apps/public-demo/v2/handler.php', 'resolve_handler_path source dir versioned');

        try {
            resolve_handler_path('public-demo', null, '../escape');
            fail_test('expected invalid source dir');
        } catch (Throwable $e) {
            assert_contains($e->getMessage(), 'source dir', 'invalid source dir message');
        }

        try {
            resolve_handler_path('public-demo', null, 'missing/demo');
            fail_test('expected unknown source dir');
        } catch (Throwable $e) {
            assert_contains($e->getMessage(), 'source dir', 'missing source dir message');
        }

        $rootResp = handle_request([
            'fn' => 'public-root',
            'fn_source_dir' => '.',
            'event' => ['method' => 'GET', 'env' => ['ROOT_MARK' => '1']],
        ]);
        $rootBody = json_decode((string) ($rootResp['body'] ?? ''), true);
        assert_same($rootBody['label'] ?? null, 'root', 'handle_request root explicit label');

        $nestedResp = handle_request([
            'fn' => 'public-demo',
            'fn_source_dir' => 'apps/public-demo',
            'event' => ['method' => 'GET', 'env' => ['FROM_REQ' => 'yes']],
        ]);
        $nestedBody = json_decode((string) ($nestedResp['body'] ?? ''), true);
        assert_same($nestedBody['label'] ?? null, 'nested', 'handle_request nested explicit label');
        assert_same(($nestedBody['env'] ?? [])['FROM_REQ'] ?? null, 'yes', 'handle_request keeps request env');
        assert_same(($nestedBody['env'] ?? [])['EXAMPLE'] ?? null, 'demo', 'handle_request merges fn.env.json');

        $nestedV2 = handle_request([
            'fn' => 'public-demo',
            'fn_source_dir' => 'apps/public-demo',
            'version' => 'v2',
            'event' => ['method' => 'GET'],
        ]);
        $nestedV2Body = json_decode((string) ($nestedV2['body'] ?? ''), true);
        assert_same($nestedV2Body['label'] ?? null, 'nested-v2', 'handle_request versioned nested explicit label');

        with_socket_pair(function ($client, $serverConn): void {
            frame_write($client, [
                'fn' => 'public-demo',
                'fn_source_dir' => 'apps/public-demo',
                'event' => ['method' => 'GET'],
            ]);
            serve_connection($serverConn);
            $reply = frame_read($client, 4096);
            $decoded = json_decode((string) $reply, true);
            assert_true(is_array($decoded), 'serve_connection reply must be json');
            assert_same($decoded['status'] ?? null, 200, 'serve_connection status');
        });
    } finally {
        shutdown_all_persistent_workers();
        restore_php_daemon_globals($snapshot);
    }
}

function test_php_daemon_worker_isolation(string $root): void
{
    global $FUNCTIONS_DIR, $RUNTIME_FN_DIR, $persistentWorkers, $composerCache, $AUTO_COMPOSER, $STRICT_FS;

    $snapshot = snapshot_php_daemon_globals();

    $tmpRoot = sys_get_temp_dir() . '/fastfn-php-daemon-isolation-' . uniqid('', true);
    if (!mkdir($tmpRoot, 0777, true) && !is_dir($tmpRoot)) {
        fail_test('failed to create temp php daemon isolation root');
    }

    $FUNCTIONS_DIR = $tmpRoot;
    $RUNTIME_FN_DIR = $tmpRoot . '/php';
    $persistentWorkers = [];
    $composerCache = [];
    $AUTO_COMPOSER = false;
    $STRICT_FS = true;

    try {
        mkdir($tmpRoot . '/tenant-a', 0777, true);
        mkdir($tmpRoot . '/tenant-b', 0777, true);
        mkdir($tmpRoot . '/env-reset', 0777, true);

        file_put_contents($tmpRoot . '/tenant-b/secret.txt', "beta-only\n");
        file_put_contents(
            $tmpRoot . '/tenant-a/handler.php',
            <<<'PHP'
<?php
function handler($event) {
    $leak = 'blocked';
    $tmpDir = sys_get_temp_dir();
    $tmpFile = tempnam($tmpDir, 'ffn');
    $tmpOk = is_string($tmpFile) && $tmpFile !== '' && @file_put_contents($tmpFile, 'ok') !== false;
    if (is_string($tmpFile) && $tmpFile !== '') {
        @unlink($tmpFile);
    }
    try {
        $raw = file_get_contents(dirname(__DIR__) . '/tenant-b/secret.txt');
        $leak = $raw === false ? 'missing' : trim($raw);
    } catch (Throwable $e) {
        $leak = 'blocked';
    }
    $token = getenv('TENANT_TOKEN');
    return [
        'status' => 200,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode([
            'fn' => 'tenant-a',
            'token' => $token === false ? null : $token,
            'leak' => $leak,
            'tmp_dir' => $tmpDir,
            'tmp_ok' => $tmpOk,
        ], JSON_UNESCAPED_SLASHES),
    ];
}
PHP
        );
        file_put_contents(
            $tmpRoot . '/tenant-b/handler.php',
            <<<'PHP'
<?php
function handler($event) {
    $token = getenv('TENANT_TOKEN');
    return [
        'status' => 200,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode([
            'fn' => 'tenant-b',
            'secret' => trim((string) file_get_contents(__DIR__ . '/secret.txt')),
            'token' => $token === false ? null : $token,
        ], JSON_UNESCAPED_SLASHES),
    ];
}
PHP
        );
        file_put_contents(
            $tmpRoot . '/env-reset/handler.php',
            <<<'PHP'
<?php
function handler($event) {
    $token = getenv('LEAK_TEST');
    return [
        'status' => 200,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode([
            'token' => $token === false ? null : $token,
        ], JSON_UNESCAPED_SLASHES),
    ];
}
PHP
        );

        $tenantA = handle_request([
            'fn' => 'tenant-a',
            'event' => ['method' => 'GET', 'env' => ['TENANT_TOKEN' => 'alpha-token']],
        ]);
        $tenantABody = json_decode((string) ($tenantA['body'] ?? ''), true);
        assert_same($tenantABody['fn'] ?? null, 'tenant-a', 'tenant-a handler label mismatch');
        assert_same($tenantABody['token'] ?? null, 'alpha-token', 'tenant-a request env mismatch');
        assert_same($tenantABody['leak'] ?? null, 'blocked', 'tenant-a should not read tenant-b files');
        assert_same($tenantABody['tmp_ok'] ?? null, true, 'tenant-a temp dir should stay writable');
        assert_true(
            is_string($tenantABody['tmp_dir'] ?? null) && strpos((string) $tenantABody['tmp_dir'], 'fastfn-php-worker-') !== false,
            'tenant-a temp dir should be isolated per handler'
        );

        $tenantB = handle_request([
            'fn' => 'tenant-b',
            'event' => ['method' => 'GET'],
        ]);
        $tenantBBody = json_decode((string) ($tenantB['body'] ?? ''), true);
        assert_same($tenantBBody['fn'] ?? null, 'tenant-b', 'tenant-b handler label mismatch');
        assert_same($tenantBBody['secret'] ?? null, 'beta-only', 'tenant-b own file read mismatch');
        assert_same($tenantBBody['token'] ?? null, null, 'tenant-b should not inherit tenant-a env');

        $firstEnv = handle_request([
            'fn' => 'env-reset',
            'event' => ['method' => 'GET', 'env' => ['LEAK_TEST' => 'first-request']],
        ]);
        $firstEnvBody = json_decode((string) ($firstEnv['body'] ?? ''), true);
        assert_same($firstEnvBody['token'] ?? null, 'first-request', 'env-reset first request token mismatch');

        $secondEnv = handle_request([
            'fn' => 'env-reset',
            'event' => ['method' => 'GET'],
        ]);
        $secondEnvBody = json_decode((string) ($secondEnv['body'] ?? ''), true);
        assert_same($secondEnvBody['token'] ?? null, null, 'env-reset should clear env between warm requests');
    } finally {
        shutdown_all_persistent_workers();
        restore_php_daemon_globals($snapshot);
    }
}

function test_php_daemon_helper_primitives(string $root): void
{
    global $RUNTIME_LOG_FILE;

    $snapshot = snapshot_php_daemon_globals();
    $tmpRoot = make_temp_dir('fastfn-php-daemon-primitives');

    try {
        json_log('unit_test', ['ok' => true]);

        $RUNTIME_LOG_FILE = $tmpRoot . '/runtime/runtime.log';
        append_runtime_log('line-one');
        assert_true(is_file($RUNTIME_LOG_FILE), 'append_runtime_log should create log file');
        assert_contains((string) file_get_contents($RUNTIME_LOG_FILE), '[php] line-one', 'append_runtime_log content mismatch');

        $RUNTIME_LOG_FILE = '';
        append_runtime_log('ignored');

        with_stream_pair(function ($left, $right): void {
            assert_true(socket_like_write($left, 'hello'), 'socket_like_write should support stream resources');
            assert_same(socket_like_read($right, 5), 'hello', 'socket_like_read should support stream resources');
            socket_like_close($left);
            assert_same(socket_like_read($right, 1), null, 'socket_like_read should return null on closed peer');
        });

        $readOnly = fopen('php://memory', 'r');
        if (!is_resource($readOnly)) {
            fail_test('failed to open read-only memory stream');
        }
        try {
            assert_same(socket_like_write($readOnly, 'x'), false, 'socket_like_write should fail on read-only streams');
        } finally {
            @fclose($readOnly);
        }

        $tempStream = fopen('php://temp', 'r+');
        if (!is_resource($tempStream)) {
            fail_test('failed to open temp stream');
        }
        socket_like_close($tempStream);
        assert_true(!is_resource($tempStream), 'socket_like_close should close stream resources');

        with_stream_pair(function ($left, $right): void {
            socket_like_write($left, pack('N', 2048));
            assert_same(frame_read($right, 64), null, 'frame_read should reject oversized frames');
        });

        with_stream_pair(function ($left, $right): void {
            socket_like_close($left);
            assert_same(frame_read($right, 64), null, 'frame_read should reject missing headers');
        });

        with_stream_pair(function ($left, $right): void {
            $bad = fopen('php://temp', 'r');
            if (!is_resource($bad)) {
                fail_test('failed to open temp stream for frame_write fallback');
            }
            try {
                frame_write($left, ['bad' => $bad]);
            } finally {
                @fclose($bad);
            }
            $raw = frame_read($right, 4096);
            assert_true(is_string($raw), 'frame_write fallback should still emit a frame');
            assert_contains((string) $raw, 'encode failed', 'frame_write fallback body mismatch');
        });
    } finally {
        remove_path($tmpRoot);
        restore_php_daemon_globals($snapshot);
    }
}

function test_php_daemon_resolution_helpers(string $root): void
{
    global $FUNCTIONS_DIR, $RUNTIME_FN_DIR;

    $snapshot = snapshot_php_daemon_globals();
    $tmpRoot = make_temp_dir('fastfn-php-daemon-resolve');
    $outsideRoot = make_temp_dir('fastfn-php-daemon-outside');

    try {
        $FUNCTIONS_DIR = $tmpRoot;
        $RUNTIME_FN_DIR = $tmpRoot . '/php';
        mkdir($RUNTIME_FN_DIR, 0777, true);

        file_put_contents($tmpRoot . '/raw-file', "<?php return;\n");
        file_put_contents($RUNTIME_FN_DIR . '/runtime-file', "<?php return;\n");

        mkdir($tmpRoot . '/index-only', 0777, true);
        file_put_contents($tmpRoot . '/index-only/index.php', "<?php return;\n");

        mkdir($tmpRoot . '/config-explicit', 0777, true);
        file_put_contents($tmpRoot . '/config-explicit/custom.php', "<?php return;\n");
        file_put_contents($tmpRoot . '/config-explicit/fn.config.json', json_encode(['entrypoint' => 'custom.php']));

        mkdir($tmpRoot . '/config-invalid', 0777, true);
        file_put_contents($tmpRoot . '/config-invalid/fn.config.json', '{invalid');
        file_put_contents($tmpRoot . '/config-invalid/handler.php', "<?php return;\n");

        mkdir($tmpRoot . '/config-outside', 0777, true);
        file_put_contents($tmpRoot . '/escape.php', "<?php return;\n");
        file_put_contents($tmpRoot . '/config-outside/fn.config.json', json_encode(['entrypoint' => '../escape.php']));

        mkdir($tmpRoot . '/nested/demo', 0777, true);
        file_put_contents($tmpRoot . '/nested/demo/handler.php', "<?php return;\n");
        @symlink($outsideRoot, $tmpRoot . '/linked-out');

        assert_same(normalize_source_dir(null), null, 'normalize_source_dir should preserve null');
        assert_same(normalize_source_dir('.'), '.', 'normalize_source_dir should allow root');
        assert_same(normalize_source_dir('nested/demo'), 'nested/demo', 'normalize_source_dir should preserve nested paths');
        assert_throws_contains(static function (): void {
            normalize_source_dir(123);
        }, 'source dir', 'normalize_source_dir should reject non-strings');
        assert_throws_contains(static function (): void {
            normalize_source_dir('   ');
        }, 'source dir', 'normalize_source_dir should reject empty paths');
        assert_throws_contains(static function (): void {
            normalize_source_dir('../escape');
        }, 'source dir', 'normalize_source_dir should reject traversal');

        assert_same(resolve_source_dir_base('.'), $tmpRoot, 'resolve_source_dir_base should resolve root');
        assert_same(resolve_source_dir_base('nested/demo'), realpath($tmpRoot . '/nested/demo'), 'resolve_source_dir_base should resolve nested dirs');
        assert_throws_contains(static function () use ($tmpRoot): void {
            global $FUNCTIONS_DIR;
            $FUNCTIONS_DIR = $tmpRoot . '/missing-root';
            resolve_source_dir_base('.');
        }, 'source dir', 'resolve_source_dir_base should reject unknown roots');
        $FUNCTIONS_DIR = $tmpRoot;
        assert_throws_contains(static function (): void {
            resolve_source_dir_base('linked-out');
        }, 'source dir', 'resolve_source_dir_base should reject symlink escapes');
        assert_throws_contains(static function (): void {
            resolve_source_dir_base('missing/demo');
        }, 'source dir', 'resolve_source_dir_base should reject unknown directories');

        assert_same(resolve_handler_path('raw-file', null), $tmpRoot . '/raw-file', 'resolve_handler_path should resolve raw root files');
        assert_same(resolve_handler_path('runtime-file', null), $RUNTIME_FN_DIR . '/runtime-file', 'resolve_handler_path should resolve runtime raw files');
        assert_same(resolve_handler_path('index-only', null), $tmpRoot . '/index-only/index.php', 'resolve_handler_path should fallback to index.php');
        assert_same(resolve_handler_path('config-explicit', null), realpath($tmpRoot . '/config-explicit/custom.php'), 'resolve_handler_path should honor explicit entrypoints');
        assert_same(resolve_handler_path('config-invalid', null), $tmpRoot . '/config-invalid/handler.php', 'resolve_handler_path should ignore broken config json');

        assert_throws_contains(static function (): void {
            resolve_handler_path('', null);
        }, 'function name', 'resolve_handler_path should reject empty names');
        assert_throws_contains(static function (): void {
            resolve_handler_path('../escape', null);
        }, 'function name', 'resolve_handler_path should reject traversal names');
        assert_throws_contains(static function (): void {
            resolve_handler_path('config-explicit', 'bad/version');
        }, 'version', 'resolve_handler_path should reject invalid versions');
        assert_throws_contains(static function (): void {
            resolve_handler_path('config-outside', null);
        }, 'unknown function', 'resolve_handler_path should reject escaped explicit entrypoints');
        assert_throws_contains(static function (): void {
            resolve_handler_path('missing', null);
        }, 'unknown function', 'resolve_handler_path should reject unknown functions');
    } finally {
        remove_path($tmpRoot);
        remove_path($outsideRoot);
        restore_php_daemon_globals($snapshot);
    }
}

function test_php_daemon_env_and_composer_helpers(string $root): void
{
    global $AUTO_COMPOSER, $COMPOSER_BIN, $composerCache, $FUNCTIONS_DIR, $RUNTIME_FN_DIR;

    $snapshot = snapshot_php_daemon_globals();
    $serverSnapshot = $_SERVER;
    $envSnapshot = $_ENV;
    $tmpRoot = make_temp_dir('fastfn-php-daemon-env');

    try {
        $FUNCTIONS_DIR = $tmpRoot;
        $RUNTIME_FN_DIR = $tmpRoot . '/php';
        mkdir($RUNTIME_FN_DIR, 0777, true);

        $envDir = $tmpRoot . '/env-demo';
        mkdir($envDir, 0777, true);
        $handlerPath = $envDir . '/handler.php';
        file_put_contents($handlerPath, "<?php return;\n");

        assert_same(read_function_env($handlerPath), [], 'read_function_env should return empty without fn.env.json');

        file_put_contents($envDir . '/fn.env.json', '{invalid');
        assert_same(read_function_env($handlerPath), [], 'read_function_env should ignore invalid json');

        file_put_contents($envDir . '/fn.env.json', '[{"value":"x"}]');
        assert_same(read_function_env($handlerPath), [], 'read_function_env should ignore non-string keys');

        file_put_contents($envDir . '/fn.env.json', json_encode([
            'A' => ['value' => 'hello'],
            'B' => ['value' => null],
            'C' => 7,
        ]));
        $fnEnv = read_function_env($handlerPath);
        assert_same($fnEnv['A'] ?? null, 'hello', 'read_function_env should extract explicit value entries');
        assert_true(!isset($fnEnv['B']), 'read_function_env should skip null explicit value entries');
        assert_same($fnEnv['C'] ?? null, '7', 'read_function_env should stringify scalar env values');

        $unreadableDir = $tmpRoot . '/env-unreadable';
        mkdir($unreadableDir, 0777, true);
        file_put_contents($unreadableDir . '/handler.php', "<?php return;\n");
        file_put_contents($unreadableDir . '/fn.env.json', '{}');
        @chmod($unreadableDir . '/fn.env.json', 0000);
        try {
            assert_same(read_function_env($unreadableDir . '/handler.php'), [], 'read_function_env should tolerate unreadable files');
        } finally {
            @chmod($unreadableDir . '/fn.env.json', 0644);
        }

        assert_same(normalize_path_for_fs($handlerPath), realpath($handlerPath), 'normalize_path_for_fs should resolve real paths');
        assert_same(normalize_path_for_fs($tmpRoot . '/missing.txt'), $tmpRoot . '/missing.txt', 'normalize_path_for_fs should preserve unresolved paths');
        assert_same(normalize_tmp_base_dir(''), '/tmp', 'normalize_tmp_base_dir should fallback to /tmp');

        $workerTmp = ensure_worker_tmp_dir($handlerPath);
        assert_true(is_dir($workerTmp), 'ensure_worker_tmp_dir should create worker temp dirs');
        assert_true(strpos($workerTmp, 'fastfn-php-worker-') !== false, 'worker temp dir should use deterministic prefix');

        $collisionHandler = $tmpRoot . '/collision/handler.php';
        mkdir(dirname($collisionHandler), 0777, true);
        file_put_contents($collisionHandler, "<?php return;\n");
        $collisionTmp = worker_tmp_dir($collisionHandler);
        file_put_contents($collisionTmp, 'occupied');
        assert_throws_contains(static function () use ($collisionHandler): void {
            ensure_worker_tmp_dir($collisionHandler);
        }, 'temp dir', 'ensure_worker_tmp_dir should reject file collisions');
        @unlink($collisionTmp);

        assert_same(is_dynamic_segment_dir('[id]'), true, 'is_dynamic_segment_dir should detect route params');
        assert_same(is_dynamic_segment_dir('orders'), false, 'is_dynamic_segment_dir should reject static directories');

        $dynamicHandler = $tmpRoot . '/items/[id]/handler.php';
        mkdir(dirname($dynamicHandler), 0777, true);
        file_put_contents($dynamicHandler, "<?php return;\n");
        assert_same(shared_scope_root_for_handler($handlerPath), null, 'shared_scope_root_for_handler should ignore static directories');
        assert_same(shared_scope_root_for_handler('[id]/handler.php'), null, 'shared_scope_root_for_handler should ignore relative top-level dynamic paths');
        assert_same(shared_scope_root_for_handler($dynamicHandler), $tmpRoot . '/items', 'shared_scope_root_for_handler should expose dynamic parent roots');
        $openBasedir = strict_open_basedir($dynamicHandler, $workerTmp);
        assert_contains($openBasedir, $tmpRoot . '/items', 'strict_open_basedir should include shared root');
        assert_contains($openBasedir, $tmpRoot . '/items/vendor', 'strict_open_basedir should include shared vendor root');
        $dedupedOpenBasedir = strict_open_basedir($dynamicHandler, '/etc/ssl');
        assert_same(substr_count($dedupedOpenBasedir, '/etc/ssl'), 1, 'strict_open_basedir should dedupe duplicate roots');

        $_SERVER = [
            'GOOD_SERVER' => 'server-value',
            'FN_ADMIN_SECRET' => 'blocked',
            'ARRAY_VALUE' => ['skip'],
            '' => 'empty-key',
            0 => 'numeric-key',
        ];
        $_ENV = [
            'GOOD_ENV' => 'env-value',
            'OBJ_VALUE' => (object) ['skip' => true],
        ];
        $workerEnv = build_worker_env(['EXTRA_NULL' => null, 'EXTRA_TEXT' => 'extra']);
        assert_same($workerEnv['GOOD_SERVER'] ?? null, 'server-value', 'build_worker_env should copy scalar server vars');
        assert_same($workerEnv['GOOD_ENV'] ?? null, 'env-value', 'build_worker_env should copy scalar env vars');
        assert_true(!isset($workerEnv['FN_ADMIN_SECRET']), 'build_worker_env should block reserved prefixes');
        assert_true(!isset($workerEnv['ARRAY_VALUE']), 'build_worker_env should skip array values');
        assert_true(!isset($workerEnv['OBJ_VALUE']), 'build_worker_env should skip object values');
        assert_same($workerEnv['EXTRA_NULL'] ?? null, '', 'build_worker_env should map null extras to empty strings');
        assert_same($workerEnv['EXTRA_TEXT'] ?? null, 'extra', 'build_worker_env should merge extra env');
        assert_true(isset($workerEnv['PATH']) && $workerEnv['PATH'] !== '', 'build_worker_env should preserve PATH');

        $composerDir = $tmpRoot . '/composer-ok';
        mkdir($composerDir, 0777, true);
        file_put_contents($composerDir . '/handler.php', "<?php return;\n");
        file_put_contents($composerDir . '/composer.json', json_encode(['require' => ['demo/package' => '1.0.0']]));
        $composerOk = $tmpRoot . '/composer-ok.sh';
        write_executable_file($composerOk, "#!/bin/sh\nmkdir -p vendor\nprintf 'ok\\n'\nexit 0\n");
        $AUTO_COMPOSER = true;
        $COMPOSER_BIN = $composerOk;
        $composerCache = [];
        ensure_composer_deps($composerDir . '/handler.php');
        assert_true(is_dir($composerDir . '/vendor'), 'ensure_composer_deps should install vendor dir');
        assert_true(isset($composerCache[$composerDir]), 'ensure_composer_deps should cache successful installs');
        ensure_composer_deps($composerDir . '/handler.php');

        $AUTO_COMPOSER = false;
        ensure_composer_deps($composerDir . '/handler.php');
        $AUTO_COMPOSER = true;
        ensure_composer_deps($handlerPath);

        $composerFailDir = $tmpRoot . '/composer-fail';
        mkdir($composerFailDir, 0777, true);
        file_put_contents($composerFailDir . '/handler.php', "<?php return;\n");
        file_put_contents($composerFailDir . '/composer.json', json_encode(['require' => ['demo/package' => '1.0.0']]));
        $composerFail = $tmpRoot . '/composer-fail.sh';
        write_executable_file($composerFail, "#!/bin/sh\necho 'composer boom'\nexit 3\n");
        $COMPOSER_BIN = $composerFail;
        $composerCache = [];
        assert_throws_contains(static function () use ($composerFailDir): void {
            ensure_composer_deps($composerFailDir . '/handler.php');
        }, 'composer install failed', 'ensure_composer_deps should surface install failures');
    } finally {
        $_SERVER = $serverSnapshot;
        $_ENV = $envSnapshot;
        remove_path($tmpRoot);
        restore_php_daemon_globals($snapshot);
    }
}

function test_php_daemon_worker_transport_and_pool(string $root): void
{
    global $FUNCTIONS_DIR, $RUNTIME_FN_DIR, $persistentWorkers, $PHP_BIN, $WORKER_IDLE_TTL_MS, $MAX_FRAME_BYTES;

    $snapshot = snapshot_php_daemon_globals();
    $tmpRoot = make_temp_dir('fastfn-php-daemon-workers');

    try {
        $FUNCTIONS_DIR = $tmpRoot;
        $RUNTIME_FN_DIR = $tmpRoot . '/php';
        mkdir($RUNTIME_FN_DIR, 0777, true);
        $persistentWorkers = [];
        $PHP_BIN = getenv('FN_PHP_BIN') ?: 'php';

        $handlerDir = $tmpRoot . '/worker-demo';
        mkdir($handlerDir, 0777, true);
        $handlerPath = $handlerDir . '/handler.php';
        file_put_contents(
            $handlerPath,
            <<<'PHP'
<?php
function handler($event) {
    if (($event['mode'] ?? '') === 'slow') {
        usleep(500000);
    }
    return [
        'status' => 200,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode(['ok' => true, 'mode' => $event['mode'] ?? 'fast'], JSON_UNESCAPED_SLASHES),
    ];
}
PHP
        );
        file_put_contents($handlerDir . '/fn.env.json', json_encode(['FLAG' => '1']));
        file_put_contents($handlerDir . '/composer.json', json_encode(['require' => ['demo/package' => '1.0.0']]));

        $signature = worker_signature($handlerPath);
        assert_contains($signature, 'handler.php:', 'worker_signature should include handler metadata');
        assert_contains($signature, 'composer.lock:missing', 'worker_signature should record missing files');
        assert_same(persistent_worker_key($handlerPath), realpath($handlerPath), 'persistent_worker_key should normalize real paths');
        assert_same(persistent_worker_key($tmpRoot . '/missing.php'), $tmpRoot . '/missing.php', 'persistent_worker_key should preserve missing paths');
        assert_throws_contains(static function () use ($tmpRoot, $signature): void {
            spawn_persistent_worker($tmpRoot . '/missing-dir/handler.php', $signature);
        }, 'failed to start php worker', 'spawn_persistent_worker should surface start failures');

        $persistentWorkers = ['ghost' => 'bad-entry'];
        shutdown_worker('ghost');
        assert_true(!isset($persistentWorkers['ghost']), 'shutdown_worker should drop invalid entries');
        assert_same(worker_is_alive(['proc' => null]), false, 'worker_is_alive should reject missing proc handles');

        $sleepProc = @proc_open([$PHP_BIN, '-r', 'usleep(500000);'], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $sleepPipes);
        if (!is_resource($sleepProc)) {
            fail_test('failed to create helper process for worker_is_alive');
        }
        try {
            assert_same(worker_is_alive(['proc' => $sleepProc]), true, 'worker_is_alive should recognize running processes');
        } finally {
            foreach ($sleepPipes as $pipe) {
                if (is_resource($pipe)) {
                    @fclose($pipe);
                }
            }
            @proc_terminate($sleepProc);
            @proc_close($sleepProc);
        }

        $workerKey = persistent_worker_key($handlerPath);
        $persistentWorkers[$workerKey] = spawn_persistent_worker($handlerPath, $signature);
        $response = send_persistent_worker_request($workerKey, ['mode' => 'fast'], 1000);
        assert_same($response['status'] ?? null, 200, 'send_persistent_worker_request should return worker response');
        assert_contains((string) ($response['body'] ?? ''), '"mode":"fast"', 'send_persistent_worker_request body mismatch');

        $sameKey = ensure_persistent_worker($handlerPath);
        assert_same($sameKey, $workerKey, 'ensure_persistent_worker should reuse live workers');
        $firstEntry = $persistentWorkers[$workerKey];
        file_put_contents($handlerPath, file_get_contents($handlerPath) . "\n");
        @touch($handlerPath, time() + 5);
        $reloadedKey = ensure_persistent_worker($handlerPath);
        assert_same($reloadedKey, $workerKey, 'ensure_persistent_worker should preserve keys');
        assert_true($persistentWorkers[$workerKey]['signature'] !== $firstEntry['signature'], 'ensure_persistent_worker should refresh stale signatures');

        $slowResp = run_worker_request($handlerPath, ['mode' => 'slow'], 10);
        assert_same($slowResp['status'] ?? null, 504, 'run_worker_request should convert timeouts to 504');
        assert_contains((string) ($slowResp['body'] ?? ''), 'timeout', 'run_worker_request timeout body mismatch');

        $persistentWorkers['invalid-reaper'] = ['signature' => 'x'];
        $WORKER_IDLE_TTL_MS = 1;
        reap_idle_workers();
        assert_true(!isset($persistentWorkers['invalid-reaper']), 'reap_idle_workers should drop malformed entries');

        $WORKER_IDLE_TTL_MS = 0;
        $persistentWorkers[$workerKey] = ['signature' => 'keep', 'last_used' => microtime(true) - 999, 'proc' => null];
        reap_idle_workers();
        assert_true(isset($persistentWorkers[$workerKey]), 'reap_idle_workers should no-op when ttl is disabled');

        $WORKER_IDLE_TTL_MS = 1;
        $persistentWorkers[$workerKey] = ['signature' => 'old', 'last_used' => microtime(true) - 999, 'proc' => null];
        reap_idle_workers();
        assert_true(!isset($persistentWorkers[$workerKey]), 'reap_idle_workers should evict stale entries');

        $persistentWorkers = [];
        $spawned = spawn_persistent_worker($handlerPath, worker_signature($handlerPath));
        shutdown_worker('missing');
        $persistentWorkers['one'] = $spawned;
        $persistentWorkers['two'] = spawn_persistent_worker($handlerPath, worker_signature($handlerPath));
        shutdown_all_persistent_workers();
        assert_same($persistentWorkers, [], 'shutdown_all_persistent_workers should empty the pool');

        $pipe = fopen('php://temp', 'r+');
        if (!is_resource($pipe)) {
            fail_test('failed to open temp stream for drain_pipe');
        }
        fwrite($pipe, str_repeat('x', 9000) . "\n");
        rewind($pipe);
        assert_same(strlen(drain_pipe($pipe)), 9000, 'drain_pipe should read long buffered streams');
        fclose($pipe);
        assert_same(drain_pipe(null), '', 'drain_pipe should ignore invalid streams');

        with_stream_pair(function ($left, $right): void {
            fwrite($left, 'ABCD');
            assert_same(stream_read_exact_with_timeout($right, 4, 200), 'ABCD', 'stream_read_exact_with_timeout should read exact payloads');
        });
        with_stream_pair(function ($left, $right): void {
            socket_like_close($left);
            assert_throws_contains(static function () use ($right): void {
                stream_read_exact_with_timeout($right, 1, 100);
            }, 'closed stdout', 'stream_read_exact_with_timeout should detect EOF');
        });
        with_stream_pair(function ($left, $right): void {
            stream_set_blocking($right, false);
            assert_throws_contains(static function () use ($right): void {
                stream_read_exact_with_timeout($right, 1, 50);
            }, 'timeout', 'stream_read_exact_with_timeout should time out');
            socket_like_close($left);
        });
        $tempReadable = fopen('php://temp', 'r+');
        if (!is_resource($tempReadable)) {
            fail_test('failed to open temp stream for stream_read_exact_with_timeout');
        }
        assert_throws_contains(static function () use ($tempReadable): void {
            stream_read_exact_with_timeout(
                $tempReadable,
                1,
                50,
                static function () {
                    return false;
                }
            );
        }, 'failed waiting', 'stream_read_exact_with_timeout should surface wait failures');
        assert_throws_contains(static function () use ($tempReadable): void {
            stream_read_exact_with_timeout(
                $tempReadable,
                1,
                50,
                static function () {
                    return 1;
                },
                static function () {
                    return false;
                }
            );
        }, 'failed reading', 'stream_read_exact_with_timeout should surface read failures');
        stream_set_blocking($tempReadable, false);
        assert_throws_contains(static function () use ($tempReadable): void {
            stream_read_exact_with_timeout(
                $tempReadable,
                1,
                50,
                static function () {
                    return 1;
                },
                static function () {
                    return '';
                }
            );
        }, 'timeout', 'stream_read_exact_with_timeout should continue on empty non-eof reads');
        fclose($tempReadable);

        assert_throws_contains(static function (): void {
            normalize_worker_response('bad');
        }, 'object', 'normalize_worker_response should require arrays');
        assert_throws_contains(static function (): void {
            normalize_worker_response(['status' => 99]);
        }, 'HTTP code', 'normalize_worker_response should validate status codes');
        assert_throws_contains(static function (): void {
            normalize_worker_response(['status' => 200, 'headers' => 'bad']);
        }, 'headers', 'normalize_worker_response should validate headers');
        assert_throws_contains(static function (): void {
            normalize_worker_response(['status' => 200, 'headers' => [], 'is_base64' => true]);
        }, 'body_base64', 'normalize_worker_response should require base64 payloads');
        $normalizedBinary = normalize_worker_response([
            'status' => 201,
            'headers' => ['Content-Type' => 'application/octet-stream'],
            'is_base64' => true,
            'body_base64' => 'YQ==',
            'stdout' => 'out',
            'stderr' => 'err',
        ]);
        assert_same($normalizedBinary['is_base64'] ?? null, true, 'normalize_worker_response should preserve base64 responses');
        assert_same($normalizedBinary['stdout'] ?? null, 'out', 'normalize_worker_response should keep stdout');
        assert_same($normalizedBinary['stderr'] ?? null, 'err', 'normalize_worker_response should keep stderr');
        $normalizedText = normalize_worker_response(['status' => 200, 'headers' => [], 'body' => null]);
        assert_same($normalizedText['body'] ?? null, '', 'normalize_worker_response should map null body to empty string');
        $normalizedScalar = normalize_worker_response(['status' => 200, 'headers' => [], 'body' => 42]);
        assert_same($normalizedScalar['body'] ?? null, '42', 'normalize_worker_response should stringify scalar bodies');

        assert_throws_contains(static function (): void {
            send_persistent_worker_request('missing', [], 100);
        }, 'missing persistent worker', 'send_persistent_worker_request should reject missing workers');

        $persistentWorkers['bad-pipes'] = ['stdin' => null, 'stdout' => null, 'stderr' => null];
        assert_throws_contains(static function (): void {
            send_persistent_worker_request('bad-pipes', [], 100);
        }, 'pipes are unavailable', 'send_persistent_worker_request should require worker pipes');

        $stdin = fopen('php://temp', 'w+');
        $stdout = fopen('php://temp', 'w+');
        $stderr = fopen('php://temp', 'w+');
        if (!is_resource($stdin) || !is_resource($stdout) || !is_resource($stderr)) {
            fail_test('failed to open temp streams for send_persistent_worker_request');
        }
        $persistentWorkers['encode-fail'] = ['stdin' => $stdin, 'stdout' => $stdout, 'stderr' => $stderr, 'last_used' => 0];
        assert_throws_contains(static function () use ($stdout): void {
            send_persistent_worker_request('encode-fail', ['bad' => $stdout], 100);
        }, 'encode', 'send_persistent_worker_request should surface encode failures');
        fclose($stdin);
        fclose($stdout);
        fclose($stderr);
        unset($persistentWorkers['encode-fail']);

        $stdin = fopen('php://memory', 'r');
        $stdout = fopen('php://temp', 'r+');
        $stderr = fopen('php://temp', 'r+');
        $persistentWorkers['write-fail'] = ['stdin' => $stdin, 'stdout' => $stdout, 'stderr' => $stderr, 'last_used' => 0];
        assert_throws_contains(static function (): void {
            send_persistent_worker_request('write-fail', ['ok' => true], 100);
        }, 'stdin write failed', 'send_persistent_worker_request should surface stdin write failures');
        fclose($stdin);
        fclose($stdout);
        fclose($stderr);
        unset($persistentWorkers['write-fail']);

        $stdin = fopen('php://temp', 'w+');
        $stdout = fopen('php://temp', 'r+');
        $stderr = fopen('php://temp', 'r+');
        fwrite($stdout, pack('N', $MAX_FRAME_BYTES + 1));
        rewind($stdout);
        $persistentWorkers['bad-frame'] = ['stdin' => $stdin, 'stdout' => $stdout, 'stderr' => $stderr, 'last_used' => 0];
        assert_throws_contains(static function (): void {
            send_persistent_worker_request('bad-frame', ['ok' => true], 100);
        }, 'frame length', 'send_persistent_worker_request should reject invalid frame lengths');
        fclose($stdin);
        fclose($stdout);
        fclose($stderr);
        unset($persistentWorkers['bad-frame']);

        $stdin = fopen('php://temp', 'w+');
        $stdout = fopen('php://temp', 'r+');
        $stderr = fopen('php://temp', 'r+');
        $invalidJson = 'not-json';
        fwrite($stdout, pack('N', strlen($invalidJson)) . $invalidJson);
        rewind($stdout);
        $persistentWorkers['bad-json'] = ['stdin' => $stdin, 'stdout' => $stdout, 'stderr' => $stderr, 'last_used' => 0];
        assert_throws_contains(static function (): void {
            send_persistent_worker_request('bad-json', ['ok' => true], 100);
        }, 'invalid php worker response', 'send_persistent_worker_request should reject invalid json');
        fclose($stdin);
        fclose($stdout);
        fclose($stderr);
        unset($persistentWorkers['bad-json']);

        $stdin = fopen('php://temp', 'w+');
        $stdout = fopen('php://temp', 'r+');
        $stderr = fopen('php://temp', 'r+');
        $payload = json_encode(['status' => 202, 'headers' => [], 'body' => 'ok', 'stderr' => 'worker']);
        fwrite($stdout, pack('N', strlen((string) $payload)) . $payload);
        fwrite($stderr, "daemon\n");
        rewind($stdout);
        rewind($stderr);
        $persistentWorkers['stderr-merge'] = ['stdin' => $stdin, 'stdout' => $stdout, 'stderr' => $stderr, 'last_used' => 0];
        $merged = send_persistent_worker_request('stderr-merge', ['ok' => true], 100);
        assert_same($merged['status'] ?? null, 202, 'send_persistent_worker_request should normalize valid responses');
        assert_contains((string) ($merged['stderr'] ?? ''), 'worker', 'send_persistent_worker_request should preserve worker stderr field');
        assert_contains((string) ($merged['stderr'] ?? ''), 'daemon', 'send_persistent_worker_request should append daemon stderr stream');
        fclose($stdin);
        fclose($stdout);
        fclose($stderr);
        unset($persistentWorkers['stderr-merge']);

        assert_same(worker_timeout_ms([]), 2500, 'worker_timeout_ms should default to 2500ms');
        assert_same(worker_timeout_ms(['context' => ['timeout_ms' => 10]]), 260, 'worker_timeout_ms should add slack to positive overrides');
        assert_same(worker_timeout_ms(['context' => ['timeout_ms' => -1]]), 2500, 'worker_timeout_ms should ignore invalid overrides');
        putenv('FN_PHP_DAEMON_MAX_CONNECTIONS=bad');
        assert_same(daemon_max_connections_from_env(), null, 'daemon_max_connections_from_env should reject invalid values');
        putenv('FN_PHP_DAEMON_MAX_CONNECTIONS');

        $emitLog = $tmpRoot . '/emit/runtime.log';
        $GLOBALS['RUNTIME_LOG_FILE'] = $emitLog;
        emit_handler_logs(
            ['fn' => 'demo', 'version' => 'v1'],
            ['stdout' => "one\n", 'stderr' => "two\n"]
        );
        $emitContents = (string) file_get_contents($emitLog);
        assert_contains($emitContents, '[fn:demo@v1 stdout] one', 'emit_handler_logs should capture stdout');
        assert_contains($emitContents, '[fn:demo@v1 stderr] two', 'emit_handler_logs should capture stderr');

        assert_throws_contains(static function (): void {
            handle_request(['event' => []]);
        }, 'fn is required', 'handle_request should require fn');
        assert_throws_contains(static function (): void {
            handle_request(['fn' => 'demo', 'event' => 'bad']);
        }, 'event must be', 'handle_request should require object events');

        assert_same(status_for_error(new RuntimeException('invalid function source dir')), 400, 'status_for_error should map invalid input to 400');
        assert_same(status_for_error(new RuntimeException('fn is required')), 400, 'status_for_error should map missing fn to 400');
        assert_same(status_for_error(new RuntimeException('event must be an object')), 400, 'status_for_error should map invalid events to 400');
        assert_same(status_for_error(new RuntimeException('unknown function')), 404, 'status_for_error should map missing handlers to 404');
        assert_same(status_for_error(new RuntimeException('boom')), 500, 'status_for_error should default to 500');
    } finally {
        shutdown_all_persistent_workers();
        remove_path($tmpRoot);
        restore_php_daemon_globals($snapshot);
    }
}

function test_php_daemon_socket_and_main_helpers(string $root): void
{
    global $FUNCTIONS_DIR, $RUNTIME_FN_DIR, $SOCKET_PATH, $WORKER_FILE;

    $snapshot = snapshot_php_daemon_globals();
    $tmpRoot = make_temp_dir('fastfn-php-daemon-sockets');

    try {
        $FUNCTIONS_DIR = $tmpRoot;
        $RUNTIME_FN_DIR = $tmpRoot . '/php';
        mkdir($RUNTIME_FN_DIR, 0777, true);
        file_put_contents(
            $tmpRoot . '/handler.php',
            "<?php\nfunction handler(\$event) { return ['status' => 200, 'headers' => ['Content-Type' => 'text/plain'], 'body' => 'main-ok']; }\n"
        );

        $socketDir = $tmpRoot . '/var/run';
        $socketPath = $socketDir . '/daemon.sock';
        ensure_socket_dir($socketPath);
        assert_true(is_dir($socketDir), 'ensure_socket_dir should create parent directories');

        prepare_socket_path($socketPath);

        file_put_contents($socketPath, 'plain-file');
        assert_throws_contains(static function () use ($socketPath): void {
            prepare_socket_path($socketPath);
        }, 'not a unix socket', 'prepare_socket_path should reject regular files');
        @unlink($socketPath);

        $server = open_daemon_server($socketPath);
        assert_true($server !== false, 'open_daemon_server should create unix socket servers');
        assert_true(file_exists($socketPath), 'open_daemon_server should materialize the socket path');
        assert_throws_contains(static function () use ($socketPath): void {
            prepare_socket_path($socketPath);
        }, 'already in use', 'prepare_socket_path should reject active sockets');
        $streamProbe = @stream_socket_server('unix://' . $tmpRoot . '/stream-probe.sock', $errno, $errstr);
        if (!is_resource($streamProbe)) {
            fail_test('failed to create stream probe socket: ' . $errstr . ' (' . $errno . ')');
        }
        assert_throws_contains(static function () use ($tmpRoot): void {
            prepare_socket_path($tmpRoot . '/stream-probe.sock', ['prefer_stream_probe' => true]);
        }, 'already in use', 'prepare_socket_path should support stream-based socket probing');
        fclose($streamProbe);
        @unlink($tmpRoot . '/stream-probe.sock');
        socket_like_close($server);
        prepare_socket_path($socketPath);
        assert_true(!file_exists($socketPath), 'prepare_socket_path should remove stale sockets');
        prepare_socket_path($socketPath, ['native_socket_api_available' => false, 'stream_socket_client_available' => false]);
        file_put_contents($tmpRoot . '/stream-plain.sock', 'plain-file');
        assert_throws_contains(static function () use ($tmpRoot): void {
            prepare_socket_path($tmpRoot . '/stream-plain.sock', ['native_socket_api_available' => false, 'stream_socket_client_available' => true]);
        }, 'not a unix socket', 'prepare_socket_path should still validate non-socket files in stream mode');
        @unlink($tmpRoot . '/stream-plain.sock');
        assert_throws_contains(static function () use ($tmpRoot): void {
            open_daemon_server($tmpRoot . '/missing/socket.sock');
        }, 'failed to bind socket', 'open_daemon_server should surface bind failures');
        assert_throws_contains(static function () use ($tmpRoot): void {
            open_daemon_server($tmpRoot . '/create-fail.sock', [
                'socket_create' => static function () {
                    return false;
                },
            ]);
        }, 'failed to create socket', 'open_daemon_server should surface socket creation failures');
        assert_throws_contains(static function () use ($tmpRoot): void {
            open_daemon_server($tmpRoot . '/listen-fail.sock', [
                'socket_listen' => static function () {
                    return false;
                },
            ]);
        }, 'failed to listen', 'open_daemon_server should surface listen failures');
        $streamServerPath = $tmpRoot . '/fallback.sock';
        $fallbackServer = open_daemon_server($streamServerPath, ['prefer_stream_server' => true, 'native_socket_api_available' => false]);
        assert_true(is_resource($fallbackServer), 'open_daemon_server should support stream fallback servers');
        fclose($fallbackServer);
        @unlink($streamServerPath);
        assert_throws_contains(static function () use ($tmpRoot): void {
            open_daemon_server($tmpRoot . '/stream-disabled.sock', [
                'prefer_stream_server' => true,
                'stream_socket_server_available' => false,
            ]);
        }, 'socket server support is required', 'open_daemon_server should reject missing stream socket support');
        assert_throws_contains(static function () use ($tmpRoot): void {
            open_daemon_server($tmpRoot . '/stream-fail.sock', [
                'prefer_stream_server' => true,
                'stream_socket_server' => static function (string $uri, &$errno, &$errstr) {
                    $errno = 55;
                    $errstr = 'stream fail';
                    return false;
                },
            ]);
        }, 'failed to bind socket', 'open_daemon_server should surface stream socket failures');

        $boundPath = $tmpRoot . '/bound.sock';
        $boundServer = open_daemon_server($boundPath);
        $pid = pcntl_fork();
        if ($pid === -1) {
            fail_test('failed to fork socket client');
        }
        if ($pid === 0) {
            usleep(100000);
            $client = @socket_create(AF_UNIX, SOCK_STREAM, 0);
            if ($client !== false && @socket_connect($client, $boundPath)) {
                frame_write($client, ['fn' => 'public-root', 'fn_source_dir' => '.', 'event' => ['method' => 'GET']]);
                frame_read($client, 4096);
                @socket_close($client);
                exit(0);
            }
            exit(1);
        }
        $accepted = accept_daemon_connection($boundServer);
        assert_true($accepted !== false, 'accept_daemon_connection should accept native sockets');
        serve_connection($accepted);
        @socket_close($boundServer);
        @pcntl_waitpid($pid, $status);
        @unlink($boundPath);

        $streamPath = $tmpRoot . '/stream.sock';
        $streamServer = @stream_socket_server('unix://' . $streamPath, $errno, $errstr);
        if (!is_resource($streamServer)) {
            fail_test('failed to open stream socket server: ' . $errstr . ' (' . $errno . ')');
        }
        $pid = pcntl_fork();
        if ($pid === -1) {
            fail_test('failed to fork stream client');
        }
        if ($pid === 0) {
            usleep(100000);
            $client = @stream_socket_client('unix://' . $streamPath, $errno, $errstr, 1.0);
            if (is_resource($client)) {
                fwrite($client, pack('N', strlen('not-json')) . 'not-json');
                frame_read($client, 4096);
                fclose($client);
                exit(0);
            }
            exit(1);
        }
        $acceptedStream = accept_daemon_connection($streamServer);
        assert_true(is_resource($acceptedStream), 'accept_daemon_connection should accept stream sockets');
        serve_connection($acceptedStream);
        fclose($streamServer);
        @pcntl_waitpid($pid, $status);
        @unlink($streamPath);

        with_socket_pair(function ($client, $serverConn): void {
            socket_like_close($client);
            serve_connection($serverConn);
        });
        with_socket_pair(function ($client, $serverConn): void {
            socket_like_write($client, pack('N', strlen('not-json')) . 'not-json');
            serve_connection($serverConn);
            $reply = frame_read($client, 4096);
            $decoded = json_decode((string) $reply, true);
            assert_same($decoded['status'] ?? null, 400, 'serve_connection should reject invalid json requests');
        });
        with_socket_pair(function ($client, $serverConn): void {
            frame_write($client, ['fn' => '', 'event' => []]);
            serve_connection($serverConn);
            $reply = frame_read($client, 4096);
            $decoded = json_decode((string) $reply, true);
            assert_same($decoded['status'] ?? null, 400, 'serve_connection should map request validation errors');
        });
        serve_connection(1);

        $WORKER_FILE = $tmpRoot . '/missing-worker.php';
        assert_same(fastfn_php_daemon_main(1), 1, 'fastfn_php_daemon_main should fail when php-worker.php is missing');

        $WORKER_FILE = $snapshot['WORKER_FILE'];
        $SOCKET_PATH = $tmpRoot . '/occupied.sock';
        file_put_contents($SOCKET_PATH, 'busy');
        assert_same(fastfn_php_daemon_main(1), 1, 'fastfn_php_daemon_main should fail when socket preparation fails');
        restore_error_handler();
        @unlink($SOCKET_PATH);

        $SOCKET_PATH = $tmpRoot . '/main.sock';
        $pid = pcntl_fork();
        if ($pid === -1) {
            fail_test('failed to fork daemon client');
        }
        if ($pid === 0) {
            usleep(150000);
            $client = @socket_create(AF_UNIX, SOCK_STREAM, 0);
            if ($client !== false && @socket_connect($client, $SOCKET_PATH)) {
                frame_write($client, ['fn' => 'public-root', 'fn_source_dir' => '.', 'event' => ['method' => 'GET']]);
                frame_read($client, 4096);
                @socket_close($client);
                exit(0);
            }
            exit(1);
        }
        assert_same(fastfn_php_daemon_main(1), 0, 'fastfn_php_daemon_main should serve bounded loops');
        try {
            filemtime($tmpRoot . '/missing-warning.txt');
            fail_test('expected custom error handler to throw');
        } catch (ErrorException $e) {
            assert_contains($e->getMessage(), 'filemtime()', 'fastfn_php_daemon_main should install the error handler');
        }
        restore_error_handler();
        @pcntl_waitpid($pid, $status);

        $idleServer = open_daemon_server($tmpRoot . '/idle.sock');
        assert_same(daemon_accept_loop($idleServer, 1, 1), 0, 'daemon_accept_loop should tolerate failed accepts when bounded by attempts');
        socket_like_close($idleServer);
    } finally {
        remove_path($tmpRoot);
        restore_php_daemon_globals($snapshot);
    }
}

function test_php_daemon_script_entrypoint(string $root): void
{
    global $daemonPath, $extraCoveredLines;

    $snapshot = snapshot_php_daemon_globals();
    $tmpRoot = make_temp_dir('fastfn-php-daemon-entry');

    try {
        file_put_contents(
            $tmpRoot . '/handler.php',
            "<?php\nfunction handler(\$event) { return ['status' => 200, 'headers' => ['Content-Type' => 'text/plain'], 'body' => 'entry-ok']; }\n"
        );

        $childCoverage = $tmpRoot . '/child-coverage.json';
        $prepend = $tmpRoot . '/prepend-coverage.php';
        file_put_contents(
            $prepend,
            <<<'PHP'
<?php
if (function_exists('xdebug_start_code_coverage')) {
    xdebug_start_code_coverage(XDEBUG_CC_UNUSED | XDEBUG_CC_DEAD_CODE);
    register_shutdown_function(static function (): void {
        $path = getenv('FASTFN_CHILD_COVERAGE');
        if (!is_string($path) || $path === '') {
            return;
        }
        $coverage = function_exists('xdebug_get_code_coverage') ? xdebug_get_code_coverage() : [];
        file_put_contents($path, json_encode($coverage, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    });
}
PHP
        );

        $socketPath = $tmpRoot . '/entry.sock';
        $env = build_worker_env([
            'FASTFN_CHILD_COVERAGE' => $childCoverage,
            'FN_FUNCTIONS_ROOT' => $tmpRoot,
            'FN_PHP_DAEMON_MAX_CONNECTIONS' => '1',
            'FN_PHP_SOCKET' => $socketPath,
            'XDEBUG_MODE' => 'coverage',
        ]);
        $cmd = [
            $snapshot['PHP_BIN'],
            '-d',
            'auto_prepend_file=' . $prepend,
            $daemonPath,
        ];
        $proc = @proc_open($cmd, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, $root, $env);
        if (!is_resource($proc)) {
            fail_test('failed to start php-daemon.php as a script');
        }

        try {
            $deadline = microtime(true) + 5.0;
            while (!file_exists($socketPath) && microtime(true) < $deadline) {
                usleep(50000);
            }
            assert_true(file_exists($socketPath), 'php-daemon.php script entrypoint should create its socket');

            $client = @socket_create(AF_UNIX, SOCK_STREAM, 0);
            if ($client === false || !@socket_connect($client, $socketPath)) {
                fail_test('failed to connect to php-daemon.php script entrypoint');
            }
            try {
                frame_write($client, ['fn' => 'public-root', 'fn_source_dir' => '.', 'event' => ['method' => 'GET']]);
                $reply = frame_read($client, 4096);
                $decoded = json_decode((string) $reply, true);
                assert_same($decoded['status'] ?? null, 200, 'php-daemon.php script entrypoint should answer requests');
                assert_same($decoded['body'] ?? null, 'entry-ok', 'php-daemon.php script entrypoint body mismatch');
            } finally {
                @socket_close($client);
            }
        } finally {
            foreach ($pipes as $pipe) {
                if (is_resource($pipe)) {
                    @fclose($pipe);
                }
            }
            $exitCode = @proc_close($proc);
            assert_same($exitCode, 0, 'php-daemon.php script entrypoint should exit cleanly');
        }

        if (is_file($childCoverage)) {
            $coverage = json_decode((string) file_get_contents($childCoverage), true);
            $daemonReal = realpath($daemonPath);
            if ($daemonReal !== false && is_array($coverage) && isset($coverage[$daemonReal]) && is_array($coverage[$daemonReal])) {
                foreach ($coverage[$daemonReal] as $lineNo => $hits) {
                    if ((int) $hits > 0) {
                        $extraCoveredLines[(int) $lineNo] = true;
                    }
                }
            }
        }
    } finally {
        remove_path($tmpRoot);
        restore_php_daemon_globals($snapshot);
    }
}

test_php_daemon_basics($root);
test_php_daemon_helper_primitives($root);
test_php_daemon_resolution_helpers($root);
test_php_daemon_env_and_composer_helpers($root);
test_php_daemon_worker_transport_and_pool($root);
test_php_daemon_socket_and_main_helpers($root);
test_php_daemon_script_entrypoint($root);
test_php_daemon_resolution_and_requests($root);
test_php_daemon_worker_isolation($root);

if ($coverageJson !== null || $coverageXml !== null) {
    write_coverage_reports($root, $daemonPath, $coverageJson, $coverageXml);
}

echo "php daemon unit tests passed\n";
