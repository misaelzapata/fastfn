#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ -n "${FORCE_COLOR:-}" && -n "${NO_COLOR:-}" ]]; then
  unset NO_COLOR
fi

echo "Testing SDK contracts..."

echo "== sdk: python =="
export PYTHONPATH="$ROOT"
python3 - <<'PY'
from sdk.python.fastfn.types import Request, Response as ResponseDict
from sdk.python.fastfn.response import Response
from sdk.python.fastfn.extras import json_response, validate

event: Request = {
    "id": "req-sdk-1",
    "ts": 1700000000000,
    "method": "GET",
    "path": "/users",
    "raw_path": "/users?active=1",
    "query": {"active": "1"},
    "headers": {"accept": "application/json"},
    "body": "",
    "client": {"ip": "127.0.0.1", "ua": "pytest"},
    "context": {"request_id": "req-sdk-1", "function_name": "users"},
    "env": {"FOO": "bar"},
}

resp: ResponseDict = Response.json({"ok": True})
txt: ResponseDict = Response.text("hello", status=201)
pxy: ResponseDict = Response.proxy("/request-inspector", "post", {"X-Trace": "abc"})

assert event["id"] == "req-sdk-1"
assert resp["status"] == 200
assert resp["headers"]["Content-Type"] == "application/json"
assert txt["status"] == 201
assert txt["headers"]["Content-Type"].startswith("text/plain")
assert txt["body"] == "hello"
assert pxy["proxy"]["path"] == "/request-inspector"
assert pxy["proxy"]["method"] == "POST"
assert pxy["proxy"]["headers"]["X-Trace"] == "abc"

jr = json_response({"ok": True}, status=201, headers={"X-Test": "1"})
assert jr["status"] == 201
assert jr["headers"]["Content-Type"] == "application/json"

try:
    from pydantic import BaseModel
except Exception:
    # validate() is optional and should fail clearly when pydantic is missing.
    try:
        validate(None, {})  # type: ignore[arg-type]
    except ImportError:
        pass
else:
    class Demo(BaseModel):
        x: int
    demo = validate(Demo, {"x": 1})
    assert demo.x == 1
print("Python SDK: OK")
PY

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
