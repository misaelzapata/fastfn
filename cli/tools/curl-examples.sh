#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"

echo "== health =="
curl -sS "$BASE_URL/_fn/health" | jq .

echo
echo "== openapi =="
curl -sS "$BASE_URL/openapi.json" | jq '.openapi, .info.title'

echo
echo "== qr python (svg) =="
curl -sS -D - "$BASE_URL/qr?text=PythonQR" -o /tmp/qr-python.svg | sed -n '1,12p'
file /tmp/qr-python.svg

echo
echo "== qr node v2 (png) =="
curl -sS "$BASE_URL/qr@v2?text=NodeQR" -o /tmp/qr-node.png
file /tmp/qr-node.png

echo
echo "== whatsapp demo start =="
curl -sS "$BASE_URL/whatsapp" | jq .

echo
echo "== whatsapp qr raw (auto-start) =="
curl -sS "$BASE_URL/whatsapp?action=qr&format=raw" | jq .

echo
echo "== whatsapp status =="
curl -sS "$BASE_URL/whatsapp?action=status" | jq .

echo
echo "== hello default =="
curl -sS "$BASE_URL/hello?name=World" | jq .

echo
echo "== hello version v2 =="
curl -sS "$BASE_URL/hello@v2?name=World" | jq .

echo
echo "== risk-score =="
curl -sS "$BASE_URL/risk-score?email=user@example.com" | jq .

echo
echo "== php-profile =="
curl -sS "$BASE_URL/php-profile?name=World" | jq .

echo
echo "== rust-profile =="
curl -sS "$BASE_URL/rust-profile?name=World" | jq .

echo
echo "== gmail-send (dry run) =="
curl -sS "$BASE_URL/gmail-send?to=demo@example.com&subject=Hi&text=Hello&dry_run=true" | jq .

echo
echo "== telegram-send (dry run) =="
curl -sS "$BASE_URL/telegram-send?chat_id=123456&text=Hello&dry_run=true" | jq .

echo
echo "== invoke helper with context =="
curl -sS "$BASE_URL/_fn/invoke" -X POST -H 'Content-Type: application/json' \
  --data '{"name":"hello","method":"GET","query":{"name":"FromInvoke"},"context":{"trace_id":"demo-123"}}' | jq .

echo
echo "== edge-filter (expect 401 without x-api-key) =="
curl -sS -i "$BASE_URL/edge-filter?user_id=123" | sed -n '1,12p'

echo
echo "== edge-filter (expect 200 with x-api-key: dev; proxied openapi) =="
curl -sS "$BASE_URL/edge-filter?user_id=123" -H 'x-api-key: dev' | jq '.openapi, .info.title'

echo
echo "== request-inspector (shows query/body/headers) =="
curl -sS "$BASE_URL/request-inspector?key=test" -X POST -H 'x-demo: 1' --data 'hello' | jq .

echo
echo "== edge-header-inject (proxies to request-inspector; injects x-tenant) =="
curl -sS "$BASE_URL/edge-header-inject?tenant=acme" -X POST -H 'Content-Type: text/plain' --data 'hello' | jq .

echo
echo "== edge-auth-gateway (expect 401 without bearer) =="
curl -sS -i "$BASE_URL/edge-auth-gateway?target=health" | sed -n '1,12p'

echo
echo "== edge-auth-gateway (expect 200 with bearer; proxied health) =="
curl -sS "$BASE_URL/edge-auth-gateway?target=health" -H 'Authorization: Bearer dev-token' | jq .

echo
echo "== github-webhook-guard (expect 401 with bad signature) =="
curl -sS -i "$BASE_URL/github-webhook-guard" -X POST -H 'x-hub-signature-256: sha256=bad' --data '{"zen":"Keep it logically awesome.","hook_id":123}' | sed -n '1,12p'

echo
echo "== telegram-ai-reply (dry run) =="
curl -sS "$BASE_URL/telegram-ai-reply?dry_run=true" -X POST -H 'Content-Type: application/json' \
  --data '{"message":{"chat":{"id":123},"text":"Hola"}}' | jq .

echo
echo "== unknown function (expect 404) =="
curl -sS -i "$BASE_URL/nope" | sed -n '1,12p'

echo
echo "== html demo =="
curl -sS -i "$BASE_URL/html-demo" | sed -n '1,20p'

echo
echo "== csv demo =="
curl -sS -i "$BASE_URL/csv-demo" | sed -n '1,20p'

echo
echo "== png demo (saved to /tmp/demo.png) =="
curl -sS "$BASE_URL/png-demo" -o /tmp/demo.png
file /tmp/demo.png
