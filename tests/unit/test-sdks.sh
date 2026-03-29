#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ -n "${FORCE_COLOR:-}" && -n "${NO_COLOR:-}" ]]; then
  unset NO_COLOR
fi

echo "Testing SDK contracts..."

echo "== sdk: python =="
export PYTHONPATH="$ROOT"
python3 "$ROOT/tests/unit/test-sdks-python.py"

echo "== sdk: js =="
if command -v node >/dev/null 2>&1; then
  (cd "$ROOT/sdk/js" && env -u NO_COLOR node smoke.test.cjs)
else
  echo "JS SDK failed (node not found)"
  exit 1
fi

echo "== sdk: php =="
if command -v php >/dev/null 2>&1; then
  ROOT_DIR="$ROOT" php <<'PHP'
<?php
require getenv('ROOT_DIR') . '/sdk/php/FastFN.php';

if (!class_exists('FastFN\\Request')) {
    fwrite(STDERR, "FastFN\\Request not found\n");
    exit(1);
}

$req = new FastFN\Request([
    'id' => 'req-sdk-php-1',
    'method' => 'POST',
    'path' => '/php',
    'query' => ['q' => '1'],
    'headers' => ['x-test' => '1'],
    'body' => ['ok' => true],
    'client' => ['ip' => '127.0.0.1'],
    'context' => ['request_id' => 'req-sdk-php-1'],
    'env' => ['TOKEN' => 'x'],
]);

if ($req->id !== 'req-sdk-php-1' || $req->method !== 'POST') {
    fwrite(STDERR, "FastFN\\Request shape mismatch\n");
    exit(1);
}

$jsonResp = FastFN\Response::json(['ok' => true], 201, ['X-Test' => '1']);
if (($jsonResp['status'] ?? 0) !== 201) {
    fwrite(STDERR, "FastFN\\Response::json status mismatch\n");
    exit(1);
}
if (($jsonResp['headers']['Content-Type'] ?? '') !== 'application/json') {
    fwrite(STDERR, "FastFN\\Response::json content-type mismatch\n");
    exit(1);
}

$textResp = FastFN\Response::text('hello', 202, ['X-Test' => '2']);
if (($textResp['status'] ?? 0) !== 202) {
    fwrite(STDERR, "FastFN\\Response::text status mismatch\n");
    exit(1);
}
if (strpos(($textResp['headers']['Content-Type'] ?? ''), 'text/plain') !== 0) {
    fwrite(STDERR, "FastFN\\Response::text content-type mismatch\n");
    exit(1);
}
if (($textResp['body'] ?? '') !== 'hello') {
    fwrite(STDERR, "FastFN\\Response::text body mismatch\n");
    exit(1);
}

$proxyResp = FastFN\Response::proxy('/request-inspector', 'GET', ['X-Trace' => 'abc']);
if (($proxyResp['proxy']['path'] ?? '') !== '/request-inspector') {
    fwrite(STDERR, "FastFN\\Response::proxy path mismatch\n");
    exit(1);
}
if (($proxyResp['proxy']['method'] ?? '') !== 'GET') {
    fwrite(STDERR, "FastFN\\Response::proxy method mismatch\n");
    exit(1);
}
if (($proxyResp['proxy']['headers']['X-Trace'] ?? '') !== 'abc') {
    fwrite(STDERR, "FastFN\\Response::proxy headers mismatch\n");
    exit(1);
}

echo "PHP SDK: OK\n";
PHP
else
  echo "PHP SDK: skipped (php not found)"
fi

echo "== sdk: rust =="
if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
  (cd "$ROOT/sdk/rust" && cargo test --quiet)
  echo "Rust SDK: OK"
else
  echo "Rust SDK: skipped (cargo/rustc not found)"
fi

echo "sdk contract tests passed"
