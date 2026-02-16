#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"

http_status() {
  local url="$1"
  local quoted

  if [[ "${FASTFN_DOCKER:-0}" == "1" ]]; then
    quoted="$(printf "%s" "$url" | sed "s/'/'\\\\''/g")"
    if code="$(docker compose exec -T openresty sh -lc "curl -sS -o /dev/null -w '%{http_code}' '$quoted'" 2>/dev/null)"; then
      echo "$code"
      return 0
    fi
    docker compose exec -T openresty sh -lc \
      "wget -q -S -O /dev/null '$quoted' 2>&1 | awk '/^  HTTP\\//{c=\\$2} END{if(c!=\"\") print c; else print \"000\"}'"
    return 0
  fi

  if code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"; then
    echo "$code"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -S -O /dev/null "$url" 2>&1 | awk '/^  HTTP\//{code=$2} END{if(code!="") print code; else print "000"}'
    return 0
  fi

  echo "000"
}

assert_status() {
  local url="$1"
  local expected="$2"
  local got
  got="$(http_status "$url")"
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL $url expected=$expected got=$got"
    exit 1
  fi
  echo "OK   $url -> $got"
}

assert_status "$BASE_URL/_fn/health" 200
assert_status "$BASE_URL/openapi.json" 200
assert_status "$BASE_URL/fn/hello?name=test" 200
assert_status "$BASE_URL/fn/hello@v2?name=test" 200
assert_status "$BASE_URL/fn/risk-score?email=a@example.com" 200
assert_status "$BASE_URL/fn/php-profile?name=test" 200
assert_status "$BASE_URL/fn/rust-profile?name=test" 200
assert_status "$BASE_URL/fn/gmail-send?to=demo@example.com&dry_run=true" 200
assert_status "$BASE_URL/fn/telegram-send?chat_id=123&dry_run=true" 200
assert_status "$BASE_URL/fn/does-not-exist" 404

echo "Smoke tests passed"
