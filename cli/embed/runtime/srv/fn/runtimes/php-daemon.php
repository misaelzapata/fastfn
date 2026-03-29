#!/usr/bin/env php
<?php
/**
 * Native PHP daemon for fastfn.
 *
 * The daemon speaks the shared FastFN socket protocol with the gateway and
 * delegates handler execution to isolated PHP worker processes. That keeps
 * PHP handlers safe even when many of them define the same global
 * `handler()` symbol.
 */

declare(strict_types=1);

$SOCKET_PATH = getenv('FN_PHP_SOCKET') ?: '/tmp/fastfn/fn-php.sock';
$MAX_FRAME_BYTES = (int) (getenv('FN_MAX_FRAME_BYTES') ?: (string) (2 * 1024 * 1024));
$STRICT_FS = !in_array(strtolower(getenv('FN_STRICT_FS') ?: '1'), ['0', 'false', 'off', 'no'], true);
$AUTO_COMPOSER = !in_array(strtolower(getenv('FN_AUTO_PHP_DEPS') ?: '1'), ['0', 'false', 'off', 'no'], true);
$RUNTIME_LOG_FILE = trim(getenv('FN_RUNTIME_LOG_FILE') ?: '');
$PHP_BIN = getenv('FN_PHP_BIN') ?: 'php';
$COMPOSER_BIN = getenv('FN_COMPOSER_BIN') ?: 'composer';
$WORKER_IDLE_TTL_MS = (int) (getenv('FN_PHP_POOL_IDLE_TTL_MS') ?: '300000');

$BASE_DIR = dirname(__DIR__);
$FUNCTIONS_DIR = getenv('FN_FUNCTIONS_ROOT') ?: ($BASE_DIR . '/functions');
$RUNTIME_FN_DIR = $FUNCTIONS_DIR . '/php';
$WORKER_FILE = __DIR__ . '/php-worker.php';

$BLOCKED_ENV_PREFIXES = ['FN_ADMIN_', 'FN_CONSOLE_', 'FN_TRUSTED_'];
$VERSION_RE = '/^[A-Za-z0-9_.\-]+$/';
$composerCache = [];
$persistentWorkers = [];

function error_response(string $msg, int $status = 500): array
{
    return [
        'status' => $status,
        'headers' => ['Content-Type' => 'application/json'],
        'body' => json_encode(['error' => $msg], JSON_UNESCAPED_SLASHES),
    ];
}

function json_log(string $event, array $fields = []): void
{
    $payload = array_merge([
        't' => gmdate('Y-m-d\TH:i:s\Z'),
        'component' => 'php_daemon',
        'event' => $event,
    ], $fields);
    fwrite(STDERR, json_encode($payload, JSON_UNESCAPED_SLASHES) . "\n");
}

function append_runtime_log(string $line): void
{
    global $RUNTIME_LOG_FILE;
    if ($RUNTIME_LOG_FILE === '') {
        return;
    }
    $dir = dirname($RUNTIME_LOG_FILE);
    if (!is_dir($dir)) {
        @mkdir($dir, 0755, true);
    }
    @file_put_contents($RUNTIME_LOG_FILE, "[php] $line\n", FILE_APPEND);
}

function is_socket_handle($conn): bool
{
    if (class_exists('Socket', false) && $conn instanceof Socket) {
        return true;
    }
    return is_resource($conn) && get_resource_type($conn) === 'Socket';
}

function socket_like_read($conn, int $length): ?string
{
    $buffer = '';
    while (strlen($buffer) < $length) {
        if (is_socket_handle($conn)) {
            $chunk = @socket_read($conn, $length - strlen($buffer), PHP_BINARY_READ);
        } else {
            $chunk = @fread($conn, $length - strlen($buffer));
        }
        if ($chunk === false || $chunk === '') {
            return null;
        }
        $buffer .= $chunk;
    }
    return $buffer;
}

function socket_like_write($conn, string $payload): bool
{
    $offset = 0;
    $length = strlen($payload);
    while ($offset < $length) {
        if (is_socket_handle($conn)) {
            $written = @socket_write($conn, substr($payload, $offset), $length - $offset);
        } else {
            $written = @fwrite($conn, substr($payload, $offset));
        }
        if ($written === false || $written === 0) {
            return false;
        }
        $offset += (int) $written;
    }
    if (!is_socket_handle($conn)) {
        @fflush($conn);
    }
    return true;
}

function socket_like_close($conn): void
{
    if (is_socket_handle($conn)) {
        @socket_close($conn);
        return;
    }
    if (is_resource($conn)) {
        @fclose($conn);
    }
}

function frame_read($conn, int $maxBytes): ?string
{
    $header = socket_like_read($conn, 4);
    if (!is_string($header) || strlen($header) !== 4) {
        return null;
    }
    $unpacked = unpack('Nlength', $header);
    $length = is_array($unpacked) && isset($unpacked['length']) ? (int) $unpacked['length'] : 0;
    if ($length <= 0 || $length > $maxBytes) {
        return null;
    }
    return socket_like_read($conn, $length);
}

function frame_write($conn, array $payload): void
{
    $encoded = json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    if (!is_string($encoded)) {
        $encoded = '{"status":500,"headers":{"Content-Type":"application/json"},"body":"{\"error\":\"encode failed\"}"}';
    }
    socket_like_write($conn, pack('N', strlen($encoded)) . $encoded);
}

function normalize_source_dir($sourceDir): ?string
{
    if ($sourceDir === null) {
        return null;
    }
    if (!is_string($sourceDir)) {
        throw new RuntimeException('invalid function source dir');
    }
    $normalized = str_replace('\\', '/', trim($sourceDir));
    if ($normalized === '') {
        throw new RuntimeException('invalid function source dir');
    }
    if (
        str_starts_with($normalized, '/') ||
        $normalized === '..' ||
        str_starts_with($normalized, '../') ||
        str_ends_with($normalized, '/..') ||
        str_contains($normalized, '/../')
    ) {
        throw new RuntimeException('invalid function source dir');
    }
    return $normalized;
}

function resolve_source_dir_base($sourceDir): ?string
{
    global $FUNCTIONS_DIR;

    $normalized = normalize_source_dir($sourceDir);
    if ($normalized === null) {
        return null;
    }

    $root = realpath($FUNCTIONS_DIR);
    if ($root === false) {
        $root = $FUNCTIONS_DIR;
    }
    $base = $normalized === '.'
        ? $root
        : (realpath($FUNCTIONS_DIR . '/' . $normalized) ?: ($FUNCTIONS_DIR . '/' . $normalized));

    if ($base !== $root && !str_starts_with($base, $root . DIRECTORY_SEPARATOR)) {
        throw new RuntimeException('invalid function source dir');
    }
    if (!is_dir($base)) {
        throw new RuntimeException('unknown function source dir');
    }
    return $base;
}

function resolve_handler_path(string $name, $version, $sourceDir = null): string
{
    global $FUNCTIONS_DIR, $RUNTIME_FN_DIR, $VERSION_RE;

    $name = trim($name);
    if ($name === '') {
        throw new RuntimeException('invalid function name');
    }

    $normalized = str_replace('\\', '/', $name);
    if (
        str_starts_with($normalized, '/') ||
        $normalized === '..' ||
        str_starts_with($normalized, '../') ||
        str_ends_with($normalized, '/..') ||
        str_contains($normalized, '/../')
    ) {
        throw new RuntimeException('invalid function name');
    }

    $sourceBase = resolve_source_dir_base($sourceDir);

    if ($sourceBase === null && ($version === null || $version === '')) {
        $direct = $FUNCTIONS_DIR . '/' . $name . '.php';
        if (is_file($direct)) {
            return $direct;
        }
        $root = $FUNCTIONS_DIR . '/' . $name;
        if (is_file($root)) {
            return $root;
        }
        $runtimeDirect = $RUNTIME_FN_DIR . '/' . $name;
        if (is_file($runtimeDirect)) {
            return $runtimeDirect;
        }
    }

    if ($sourceBase !== null) {
        $base = $sourceBase;
    } else {
        $base = $FUNCTIONS_DIR . '/' . $name;
        if (!file_exists($base)) {
            $runtimeBase = $RUNTIME_FN_DIR . '/' . $name;
            if (file_exists($runtimeBase)) {
                $base = $runtimeBase;
            }
        }
    }

    $target = $base;
    if ($version !== null && $version !== '') {
        if (!is_string($version) || !preg_match($VERSION_RE, $version)) {
            throw new RuntimeException('invalid function version');
        }
        $target = $base . '/' . $version;
    }

    $configPath = $target . '/fn.config.json';
    if (is_file($configPath)) {
        $raw = @file_get_contents($configPath);
        if (is_string($raw)) {
            $config = json_decode($raw, true);
            if (is_array($config) && isset($config['entrypoint']) && is_string($config['entrypoint'])) {
                $explicit = realpath($target . '/' . $config['entrypoint']);
                if ($explicit !== false && is_file($explicit)) {
                    $targetReal = realpath($target);
                    if ($targetReal !== false && str_starts_with($explicit, $targetReal . DIRECTORY_SEPARATOR)) {
                        return $explicit;
                    }
                }
            }
        }
    }

    foreach (['handler.php', 'index.php'] as $candidate) {
        $path = $target . '/' . $candidate;
        if (is_file($path)) {
            return $path;
        }
    }

    throw new RuntimeException('unknown function');
}

function read_function_env(string $handlerPath): array
{
    $envPath = dirname($handlerPath) . '/fn.env.json';
    if (!is_file($envPath)) {
        return [];
    }
    $raw = @file_get_contents($envPath);
    if (!is_string($raw)) {
        return [];
    }
    $data = json_decode($raw, true);
    if (!is_array($data)) {
        return [];
    }

    $out = [];
    foreach ($data as $k => $v) {
        if (!is_string($k)) {
            continue;
        }
        if (is_array($v) && array_key_exists('value', $v)) {
            if ($v['value'] === null) {
                continue;
            }
            $out[$k] = (string) $v['value'];
            continue;
        }
        if ($v !== null) {
            $out[$k] = (string) $v;
        }
    }
    return $out;
}

function normalize_path_for_fs(string $path): string
{
    $real = realpath($path);
    return $real !== false ? $real : $path;
}

function normalize_tmp_base_dir(string $base): string
{
    $normalized = rtrim($base, DIRECTORY_SEPARATOR);
    return $normalized !== '' ? $normalized : '/tmp';
}

function worker_tmp_dir(string $handlerPath): string
{
    $real = realpath($handlerPath);
    $fingerprint = substr(hash('sha256', $real !== false ? $real : $handlerPath), 0, 24);
    $base = normalize_tmp_base_dir((string) sys_get_temp_dir());
    return $base . DIRECTORY_SEPARATOR . 'fastfn-php-worker-' . $fingerprint;
}

function ensure_worker_tmp_dir(string $handlerPath): string
{
    $tmpDir = worker_tmp_dir($handlerPath);
    if (!is_dir($tmpDir) && !@mkdir($tmpDir, 0700, true) && !is_dir($tmpDir)) {
        throw new RuntimeException('failed to create php worker temp dir');
    }
    return $tmpDir;
}

function is_dynamic_segment_dir(string $dirName): bool
{
    return $dirName !== '' && str_starts_with($dirName, '[') && str_ends_with($dirName, ']');
}

function shared_scope_root_for_handler(string $handlerPath): ?string
{
    $handlerDir = dirname($handlerPath);
    $leafDir = basename($handlerDir);
    if (!is_dynamic_segment_dir($leafDir)) {
        return null;
    }

    $sharedRoot = dirname($handlerDir);
    if ($sharedRoot === '' || $sharedRoot === '.' || $sharedRoot === $handlerDir) {
        return null;
    }
    return $sharedRoot;
}

function strict_open_basedir(string $handlerPath, string $workerTmpDir): string
{
    $roots = [
        normalize_path_for_fs(dirname($handlerPath)),
        normalize_path_for_fs(dirname($handlerPath) . '/vendor'),
        normalize_path_for_fs($workerTmpDir),
        '/etc/ssl',
        '/etc/pki',
        '/usr/share/zoneinfo',
    ];
    $sharedRoot = shared_scope_root_for_handler($handlerPath);
    if (is_string($sharedRoot) && $sharedRoot !== '') {
        $roots[] = normalize_path_for_fs($sharedRoot);
        $roots[] = normalize_path_for_fs($sharedRoot . '/vendor');
    }

    $seen = [];
    $ordered = [];
    foreach ($roots as $root) {
        if (isset($seen[$root])) {
            continue;
        }
        $seen[$root] = true;
        $ordered[] = $root;
    }
    return implode(':', $ordered);
}

function ensure_composer_deps(string $handlerPath): void
{
    global $AUTO_COMPOSER, $COMPOSER_BIN, $composerCache;

    if (!$AUTO_COMPOSER) {
        return;
    }

    $fnDir = dirname($handlerPath);
    $composerJson = $fnDir . '/composer.json';
    if (!is_file($composerJson)) {
        return;
    }

    $jsonMtime = (string) filemtime($composerJson);
    $lockFile = $fnDir . '/composer.lock';
    $lockMtime = is_file($lockFile) ? (string) filemtime($lockFile) : '0';
    $marker = $jsonMtime . ':' . $lockMtime;

    if (isset($composerCache[$fnDir]) && $composerCache[$fnDir] === $marker && is_dir($fnDir . '/vendor')) {
        return;
    }

    $output = [];
    $exitCode = 0;
    $cmd = escapeshellcmd($COMPOSER_BIN)
        . ' install --no-dev --no-interaction --no-progress --prefer-dist --no-scripts 2>&1';
    exec('cd ' . escapeshellarg($fnDir) . ' && ' . $cmd, $output, $exitCode);
    if ($exitCode !== 0) {
        $tail = implode(' | ', array_slice($output, -4));
        throw new RuntimeException('composer install failed: ' . ($tail !== '' ? $tail : 'unknown error'));
    }

    $composerCache[$fnDir] = $marker;
}

function build_worker_env(array $extra = []): array
{
    global $BLOCKED_ENV_PREFIXES;

    $merged = array_merge($_SERVER, $_ENV);
    $env = [];
    foreach ($merged as $k => $v) {
        if (!is_string($k) || $k === '') {
            continue;
        }
        $blocked = false;
        foreach ($BLOCKED_ENV_PREFIXES as $prefix) {
            if (str_starts_with($k, $prefix)) {
                $blocked = true;
                break;
            }
        }
        if ($blocked || is_array($v) || is_object($v)) {
            continue;
        }
        $env[$k] = (string) $v;
    }

    $path = getenv('PATH');
    if (is_string($path) && $path !== '') {
        $env['PATH'] = $path;
    }

    foreach ($extra as $k => $v) {
        if (is_string($k) && $k !== '') {
            $env[$k] = $v === null ? '' : (string) $v;
        }
    }
    return $env;
}

function worker_signature(string $handlerPath): string
{
    global $WORKER_FILE;

    $files = [
        $handlerPath,
        dirname($handlerPath) . '/fn.env.json',
        dirname($handlerPath) . '/composer.json',
        dirname($handlerPath) . '/composer.lock',
        $WORKER_FILE,
    ];

    $parts = [];
    foreach ($files as $path) {
        if (is_file($path)) {
            $parts[] = basename($path) . ':' . filemtime($path) . ':' . filesize($path);
        } else {
            $parts[] = basename($path) . ':missing';
        }
    }
    return implode('|', $parts);
}

function persistent_worker_key(string $handlerPath): string
{
    $real = realpath($handlerPath);
    return $real !== false ? $real : $handlerPath;
}

function shutdown_worker(string $workerKey): void
{
    global $persistentWorkers;

    $entry = $persistentWorkers[$workerKey] ?? null;
    if (!is_array($entry)) {
        unset($persistentWorkers[$workerKey]);
        return;
    }

    foreach (['stdin', 'stdout', 'stderr'] as $pipeKey) {
        $pipe = $entry[$pipeKey] ?? null;
        if (is_resource($pipe)) {
            @fclose($pipe);
        }
    }

    $proc = $entry['proc'] ?? null;
    if (is_resource($proc)) {
        @proc_terminate($proc);
        $status = @proc_get_status($proc);
        if (is_array($status) && !empty($status['running'])) {
            usleep(100000);
            @proc_terminate($proc, 9);
        }
        @proc_close($proc);
    }

    unset($persistentWorkers[$workerKey]);
}

function shutdown_all_persistent_workers(): void
{
    global $persistentWorkers;
    foreach (array_keys($persistentWorkers) as $workerKey) {
        shutdown_worker((string) $workerKey);
    }
}

function worker_is_alive(array $entry): bool
{
    $proc = $entry['proc'] ?? null;
    if (!is_resource($proc)) {
        return false;
    }
    $status = @proc_get_status($proc);
    return is_array($status) && !empty($status['running']);
}

function spawn_persistent_worker(string $handlerPath, string $signature): array
{
    global $PHP_BIN, $STRICT_FS, $WORKER_FILE;

    $workerTmpDir = ensure_worker_tmp_dir($handlerPath);
    $cmd = [$PHP_BIN, '-d', 'display_errors=0', '-d', 'log_errors=0'];
    if ($STRICT_FS) {
        $cmd[] = '-d';
        $cmd[] = 'open_basedir=' . strict_open_basedir($handlerPath, $workerTmpDir);
    }
    $cmd[] = $WORKER_FILE;
    $cmd[] = $handlerPath;

    $descriptors = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];
    $proc = @proc_open(
        $cmd,
        $descriptors,
        $pipes,
        dirname($handlerPath),
        build_worker_env([
            'FN_STRICT_FS' => $STRICT_FS ? '1' : '0',
            'FN_PHP_TMPDIR' => $workerTmpDir,
            '_FASTFN_WORKER_MODE' => 'persistent',
            'TMPDIR' => $workerTmpDir,
            'TMP' => $workerTmpDir,
            'TEMP' => $workerTmpDir,
        ])
    );

    if (!is_resource($proc) || !isset($pipes[0], $pipes[1], $pipes[2])) {
        throw new RuntimeException('failed to start php worker');
    }

    stream_set_write_buffer($pipes[0], 0);
    stream_set_read_buffer($pipes[1], 0);
    stream_set_read_buffer($pipes[2], 0);
    stream_set_blocking($pipes[0], true);
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);

    return [
        'proc' => $proc,
        'stdin' => $pipes[0],
        'stdout' => $pipes[1],
        'stderr' => $pipes[2],
        'signature' => $signature,
        'last_used' => microtime(true),
        'handler_path' => $handlerPath,
    ];
}

function reap_idle_workers(?string $keepWorkerKey = null): void
{
    global $persistentWorkers, $WORKER_IDLE_TTL_MS;

    if ($WORKER_IDLE_TTL_MS <= 0) {
        return;
    }

    $now = microtime(true);
    foreach ($persistentWorkers as $workerKey => $entry) {
        if ($keepWorkerKey !== null && $workerKey === $keepWorkerKey) {
            continue;
        }
        if (!is_array($entry) || !isset($entry['last_used'])) {
            shutdown_worker((string) $workerKey);
            continue;
        }
        $idleForMs = (int) (($now - (float) $entry['last_used']) * 1000);
        if ($idleForMs >= $WORKER_IDLE_TTL_MS || !worker_is_alive($entry)) {
            shutdown_worker((string) $workerKey);
        }
    }
}

function ensure_persistent_worker(string $handlerPath): string
{
    global $persistentWorkers;

    $workerKey = persistent_worker_key($handlerPath);
    reap_idle_workers($workerKey);

    $signature = worker_signature($handlerPath);
    $existing = $persistentWorkers[$workerKey] ?? null;
    if (
        is_array($existing) &&
        ($existing['signature'] ?? '') === $signature &&
        worker_is_alive($existing)
    ) {
        $existing['last_used'] = microtime(true);
        $persistentWorkers[$workerKey] = $existing;
        return $workerKey;
    }

    if ($existing !== null) {
        shutdown_worker($workerKey);
    }

    $persistentWorkers[$workerKey] = spawn_persistent_worker($handlerPath, $signature);
    return $workerKey;
}

function drain_pipe($stream): string
{
    if (!is_resource($stream)) {
        return '';
    }
    $data = '';
    while (true) {
        $chunk = @stream_get_contents($stream);
        if ($chunk === false || $chunk === '') {
            break;
        }
        $data .= $chunk;
        if (strlen($chunk) < 8192) {
            break;
        }
    }
    return trim($data);
}

function stream_read_exact_with_timeout($stream, int $length, int $timeoutMs, ?callable $waitForRead = null, ?callable $readChunk = null): string
{
    $buffer = '';
    $deadline = microtime(true) + max(0.1, $timeoutMs / 1000.0);

    while (strlen($buffer) < $length) {
        $remaining = $deadline - microtime(true);
        if ($remaining <= 0) {
            throw new RuntimeException('php worker timeout');
        }

        $read = [$stream];
        $write = null;
        $except = null;
        $sec = (int) floor($remaining);
        $usec = (int) floor(($remaining - $sec) * 1000000);
        $ready = $waitForRead !== null
            ? $waitForRead($stream, $sec, $usec)
            : @stream_select($read, $write, $except, $sec, $usec);
        if ($ready === false) {
            throw new RuntimeException('failed waiting for php worker response');
        }
        if ($ready === 0) {
            continue;
        }

        $chunk = $readChunk !== null
            ? $readChunk($stream, $length - strlen($buffer))
            : @fread($stream, $length - strlen($buffer));
        if ($chunk === false) {
            throw new RuntimeException('failed reading php worker response');
        }
        if ($chunk === '') {
            if (feof($stream)) {
                throw new RuntimeException('php worker closed stdout');
            }
            continue;
        }

        $buffer .= $chunk;
    }

    return $buffer;
}

function normalize_worker_response($parsed): array
{
    if (!is_array($parsed)) {
        throw new RuntimeException('worker response must be an object');
    }

    $status = $parsed['status'] ?? null;
    if (!is_int($status) || $status < 100 || $status > 599) {
        throw new RuntimeException('worker response status must be a valid HTTP code');
    }

    $headers = $parsed['headers'] ?? [];
    if (!is_array($headers)) {
        throw new RuntimeException('worker response headers must be an object');
    }

    if (!empty($parsed['is_base64'])) {
        $bodyBase64 = $parsed['body_base64'] ?? '';
        if (!is_string($bodyBase64) || $bodyBase64 === '') {
            throw new RuntimeException('worker response body_base64 is required');
        }
        $normalized = [
            'status' => $status,
            'headers' => $headers,
            'is_base64' => true,
            'body_base64' => $bodyBase64,
        ];
    } else {
        $body = array_key_exists('body', $parsed) ? $parsed['body'] : '';
        if ($body === null) {
            $body = '';
        }
        if (!is_string($body)) {
            $body = (string) $body;
        }
        $normalized = [
            'status' => $status,
            'headers' => $headers,
            'body' => $body,
        ];
    }

    if (isset($parsed['stdout']) && is_string($parsed['stdout']) && $parsed['stdout'] !== '') {
        $normalized['stdout'] = $parsed['stdout'];
    }
    if (isset($parsed['stderr']) && is_string($parsed['stderr']) && $parsed['stderr'] !== '') {
        $normalized['stderr'] = $parsed['stderr'];
    }

    return $normalized;
}

function send_persistent_worker_request(string $workerKey, array $event, int $timeoutMs): array
{
    global $persistentWorkers, $MAX_FRAME_BYTES;

    if (!isset($persistentWorkers[$workerKey]) || !is_array($persistentWorkers[$workerKey])) {
        throw new RuntimeException('missing persistent worker');
    }

    $entry = $persistentWorkers[$workerKey];
    $stdin = $entry['stdin'] ?? null;
    $stdout = $entry['stdout'] ?? null;
    $stderr = $entry['stderr'] ?? null;
    if (!is_resource($stdin) || !is_resource($stdout)) {
        throw new RuntimeException('php worker pipes are unavailable');
    }

    $payload = json_encode($event, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    if (!is_string($payload)) {
        throw new RuntimeException('failed to encode php worker request');
    }
    if (!socket_like_write($stdin, pack('N', strlen($payload)) . $payload)) {
        throw new RuntimeException('php worker stdin write failed');
    }

    $header = stream_read_exact_with_timeout($stdout, 4, $timeoutMs);
    $unpacked = unpack('Nlength', $header);
    $length = is_array($unpacked) && isset($unpacked['length']) ? (int) $unpacked['length'] : 0;
    if ($length <= 0 || $length > $MAX_FRAME_BYTES) {
        throw new RuntimeException('invalid php worker frame length');
    }

    $raw = stream_read_exact_with_timeout($stdout, $length, $timeoutMs);
    $parsed = json_decode($raw, true);
    if (json_last_error() !== JSON_ERROR_NONE) {
        throw new RuntimeException('invalid php worker response');
    }

    $normalized = normalize_worker_response($parsed);
    $stderrOutput = drain_pipe($stderr);
    if ($stderrOutput !== '') {
        $existing = $normalized['stderr'] ?? '';
        $normalized['stderr'] = trim($existing !== '' ? ($existing . "\n" . $stderrOutput) : $stderrOutput);
    }

    $entry['last_used'] = microtime(true);
    $persistentWorkers[$workerKey] = $entry;

    return $normalized;
}

function worker_timeout_ms(array $event): int
{
    $timeoutMs = 2500;
    $context = $event['context'] ?? null;
    if (is_array($context)) {
        $value = $context['timeout_ms'] ?? null;
        if ((is_int($value) || is_float($value)) && $value > 0) {
            $timeoutMs = (int) $value + 250;
        }
    }
    return $timeoutMs;
}

function run_worker_request(string $handlerPath, array $event, int $timeoutMs): array
{
    $lastError = null;

    for ($attempt = 0; $attempt < 2; $attempt++) {
        $workerKey = ensure_persistent_worker($handlerPath);
        try {
            return send_persistent_worker_request($workerKey, $event, $timeoutMs);
        } catch (Throwable $e) {
            $lastError = $e;
            shutdown_worker($workerKey);
        }
    }

    $message = $lastError instanceof Throwable ? $lastError->getMessage() : 'php worker failed';
    $status = str_contains(strtolower($message), 'timeout') ? 504 : 500;
    return error_response($message, $status);
}

function emit_handler_logs(array $req, array $resp): void
{
    $fnLabel = ($req['fn'] ?? 'unknown') . '@' . ($req['version'] ?? 'default');

    if (!empty($resp['stdout']) && is_string($resp['stdout'])) {
        foreach (explode("\n", $resp['stdout']) as $line) {
            if ($line === '') {
                continue;
            }
            $log = "[fn:$fnLabel stdout] $line";
            fwrite(STDOUT, $log . "\n");
            append_runtime_log($log);
        }
    }

    if (!empty($resp['stderr']) && is_string($resp['stderr'])) {
        foreach (explode("\n", $resp['stderr']) as $line) {
            if ($line === '') {
                continue;
            }
            $log = "[fn:$fnLabel stderr] $line";
            fwrite(STDERR, $log . "\n");
            append_runtime_log($log);
        }
    }
}

function handle_request(array $req): array
{
    $fnName = $req['fn'] ?? null;
    if (!is_string($fnName) || $fnName === '') {
        throw new RuntimeException('fn is required');
    }

    $event = $req['event'] ?? [];
    if (!is_array($event)) {
        throw new RuntimeException('event must be an object');
    }

    $handlerPath = resolve_handler_path($fnName, $req['version'] ?? null, $req['fn_source_dir'] ?? null);
    ensure_composer_deps($handlerPath);

    $fnEnv = read_function_env($handlerPath);
    if ($fnEnv !== []) {
        $event['env'] = array_merge(is_array($event['env'] ?? null) ? $event['env'] : [], $fnEnv);
    }

    return run_worker_request($handlerPath, $event, worker_timeout_ms($event));
}

function status_for_error(Throwable $e): int
{
    $message = strtolower($e->getMessage());
    if (
        str_contains($message, 'invalid function') ||
        str_contains($message, 'fn is required') ||
        str_contains($message, 'event must be')
    ) {
        return 400;
    }
    if (str_contains($message, 'unknown function')) {
        return 404;
    }
    return 500;
}

function serve_connection($conn): void
{
    global $MAX_FRAME_BYTES;

    try {
        $raw = frame_read($conn, $MAX_FRAME_BYTES);
        if (!is_string($raw) || $raw === '') {
            socket_like_close($conn);
            return;
        }

        $req = json_decode($raw, true);
        if (!is_array($req)) {
            frame_write($conn, error_response('invalid request', 400));
            socket_like_close($conn);
            return;
        }

        try {
            $resp = handle_request($req);
        } catch (Throwable $e) {
            $resp = error_response($e->getMessage(), status_for_error($e));
        }

        emit_handler_logs($req, $resp);
        frame_write($conn, $resp);
    } catch (Throwable $e) {
        try {
            frame_write($conn, error_response('internal error: ' . $e->getMessage(), 500));
        } catch (Throwable $_) {
            // Broken connection, nothing else to do.
        }
    }

    socket_like_close($conn);
}

function ensure_socket_dir(string $path): void
{
    $dir = dirname($path);
    if (!is_dir($dir)) {
        @mkdir($dir, 0755, true);
    }
}

function prepare_socket_path(string $path, array $options = []): void
{
    $preferStreamProbe = !empty($options['prefer_stream_probe']);
    $nativeSocketApiAvailable = array_key_exists('native_socket_api_available', $options)
        ? (bool) $options['native_socket_api_available']
        : function_exists('socket_create');
    $streamSocketClientAvailable = array_key_exists('stream_socket_client_available', $options)
        ? (bool) $options['stream_socket_client_available']
        : function_exists('stream_socket_client');

    if (!file_exists($path)) {
        return;
    }

    $stat = @lstat($path);
    if ($stat !== false && (($stat['mode'] & 0xF000) !== 0xC000)) {
        throw new RuntimeException('runtime socket path exists and is not a unix socket: ' . $path);
    }

    if ($nativeSocketApiAvailable && !$preferStreamProbe) {
        $probe = @socket_create(AF_UNIX, SOCK_STREAM, 0);
        if ($probe !== false) {
            $connected = @socket_connect($probe, $path);
            @socket_close($probe);
            if ($connected) {
                throw new RuntimeException('runtime socket already in use: ' . $path);
            }
        }
    } elseif ($streamSocketClientAvailable) {
        $probe = @stream_socket_client('unix://' . $path, $errno, $errstr, 0.2);
        if (is_resource($probe)) {
            @fclose($probe);
            throw new RuntimeException('runtime socket already in use: ' . $path);
        }
    }

    @unlink($path);
}

function open_daemon_server(string $path, array $options = [])
{
    $preferStreamServer = !empty($options['prefer_stream_server']);
    $nativeSocketApiAvailable = array_key_exists('native_socket_api_available', $options)
        ? (bool) $options['native_socket_api_available']
        : function_exists('socket_create');
    $streamSocketServerAvailable = array_key_exists('stream_socket_server_available', $options)
        ? (bool) $options['stream_socket_server_available']
        : function_exists('stream_socket_server');
    $socketCreate = $options['socket_create'] ?? static function () {
        return @socket_create(AF_UNIX, SOCK_STREAM, 0);
    };
    $socketBind = $options['socket_bind'] ?? static function ($server, string $socketPath): bool {
        return @socket_bind($server, $socketPath);
    };
    $socketListen = $options['socket_listen'] ?? static function ($server, int $backlog): bool {
        return @socket_listen($server, $backlog);
    };
    $socketClose = $options['socket_close'] ?? static function ($server): void {
        @socket_close($server);
    };
    $streamServerFactory = $options['stream_socket_server'] ?? static function (string $uri, &$errno, &$errstr) {
        return @stream_socket_server($uri, $errno, $errstr);
    };

    if ($nativeSocketApiAvailable && !$preferStreamServer) {
        $server = $socketCreate();
        if ($server === false) {
            $errno = socket_last_error();
            throw new RuntimeException('failed to create socket ' . $path . ': ' . socket_strerror($errno) . " ($errno)");
        }
        if (!$socketBind($server, $path)) {
            $errno = socket_last_error($server);
            $socketClose($server);
            throw new RuntimeException('failed to bind socket ' . $path . ': ' . socket_strerror($errno) . " ($errno)");
        }
        if (!$socketListen($server, 128)) {
            $errno = socket_last_error($server);
            $socketClose($server);
            throw new RuntimeException('failed to listen on socket ' . $path . ': ' . socket_strerror($errno) . " ($errno)");
        }
        return $server;
    }

    if (!$streamSocketServerAvailable) {
        throw new RuntimeException('php socket server support is required for php-daemon.php');
    }

    $errno = 0;
    $errstr = '';
    $server = $streamServerFactory('unix://' . $path, $errno, $errstr);
    if (!is_resource($server)) {
        throw new RuntimeException('failed to bind socket ' . $path . ': ' . $errstr . " ($errno)");
    }
    return $server;
}

function accept_daemon_connection($server, ?float $timeoutSeconds = null)
{
    if (is_socket_handle($server)) {
        if ($timeoutSeconds !== null && $timeoutSeconds <= 0) {
            @socket_set_nonblock($server);
            $conn = @socket_accept($server);
            @socket_set_block($server);
            return $conn;
        }
        return @socket_accept($server);
    }
    $timeout = $timeoutSeconds ?? -1;
    return @stream_socket_accept($server, $timeout);
}

function daemon_accept_loop($server, ?int $maxConnections = null, ?int $maxAttempts = null): int
{
    $served = 0;
    $attempts = 0;
    while (($maxConnections === null || $served < $maxConnections) && ($maxAttempts === null || $attempts < $maxAttempts)) {
        $attempts++;
        $conn = accept_daemon_connection($server, $maxAttempts !== null ? 0.0 : null);
        if ($conn === false) {
            continue;
        }
        serve_connection($conn);
        $served++;
    }

    return 0;
}

function daemon_max_connections_from_env(): ?int
{
    $raw = getenv('FN_PHP_DAEMON_MAX_CONNECTIONS');
    if (!is_string($raw) || $raw === '' || !preg_match('/^\d+$/', $raw)) {
        return null;
    }
    return (int) $raw;
}

function fastfn_php_daemon_main(?int $maxConnections = null): int
{
    global $SOCKET_PATH, $WORKER_FILE;

    if ($maxConnections === null) {
        $maxConnections = daemon_max_connections_from_env();
    }

    if (!is_file($WORKER_FILE)) {
        fwrite(STDERR, "missing php-worker.php\n");
        return 1;
    }

    set_error_handler(static function (int $severity, string $message, string $file, int $line): bool {
        throw new ErrorException($message, 0, $severity, $file, $line);
    });

    ensure_socket_dir($SOCKET_PATH);
    try {
        prepare_socket_path($SOCKET_PATH);
        $server = open_daemon_server($SOCKET_PATH);
    } catch (Throwable $e) {
        fwrite(STDERR, $e->getMessage() . "\n");
        return 1;
    }

    @chmod($SOCKET_PATH, 0666);
    json_log('started', ['socket' => $SOCKET_PATH, 'pid' => getmypid()]);
    return daemon_accept_loop($server, $maxConnections);
}

register_shutdown_function('shutdown_all_persistent_workers');

$fastfnScriptPath = isset($_SERVER['SCRIPT_FILENAME']) ? realpath((string) $_SERVER['SCRIPT_FILENAME']) : false;
if ($fastfnScriptPath !== false && $fastfnScriptPath === __FILE__) {
    exit(fastfn_php_daemon_main());
}
