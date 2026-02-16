#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fastfn_lua_test_${RANDOM}_$$}"
DC=(docker compose -p "$PROJECT_NAME" -f "$ROOT_DIR/docker-compose.yml")
LUA_COVERAGE="${LUA_COVERAGE:-0}"
COVERAGE_DIR="${COVERAGE_DIR:-$ROOT_DIR/coverage/lua}"

cleanup() {
  "${DC[@]}" down --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Build image to ensure the exact same OpenResty runtime used in integration.
"${DC[@]}" build openresty >/dev/null

if [[ "$LUA_COVERAGE" == "1" ]]; then
  if [[ "$COVERAGE_DIR" != /* ]]; then
    COVERAGE_DIR="$ROOT_DIR/$COVERAGE_DIR"
  fi
  mkdir -p "$COVERAGE_DIR"
  "${DC[@]}" run --rm --no-deps \
    -v "$ROOT_DIR/tests:/app/tests" \
    -v "$COVERAGE_DIR:/app/coverage/lua" \
    openresty \
    sh -lc '
      set -e
      find_luacov_bin() {
        # 1) Standard PATH first.
        b="$(command -v luacov || command -v luacov-5.1 || true)"
        if [ -n "$b" ]; then
          printf "%s\n" "$b"
          return 0
        fi

        # 1b) whereis when available (not always present in Alpine images).
        if command -v whereis >/dev/null 2>&1; then
          for n in luacov luacov-5.1; do
            c="$(whereis -b "$n" 2>/dev/null | tr " " "\n" | grep "^/" | head -n1 || true)"
            if [ -n "$c" ] && [ -x "$c" ]; then
              printf "%s\n" "$c"
              return 0
            fi
          done
        fi

        # 2) Common explicit bin dirs.
        for d in /usr/local/bin /usr/bin /root/.luarocks/bin /home/*/.luarocks/bin; do
          [ -d "$d" ] || continue
          for n in luacov luacov-5.1; do
            if [ -x "$d/$n" ]; then
              printf "%s\n" "$d/$n"
              return 0
            fi
          done
        done

        # 3) Rock tree fallback where wrapper may not be linked into PATH.
        for p in \
          /usr/local/lib/luarocks/rocks-5.1/luacov/*/bin/luacov \
          /usr/local/lib/luarocks/rocks-5.1/luacov/*/bin/luacov-5.1 \
          /usr/lib/luarocks/rocks-5.1/luacov/*/bin/luacov \
          /usr/lib/luarocks/rocks-5.1/luacov/*/bin/luacov-5.1 \
          /root/.luarocks/lib/luarocks/rocks-5.1/luacov/*/bin/luacov \
          /root/.luarocks/lib/luarocks/rocks-5.1/luacov/*/bin/luacov-5.1
        do
          if [ -x "$p" ]; then
            printf "%s\n" "$p"
            return 0
          fi
        done

        return 1
      }

      RESTY_BIN="$(command -v resty || true)"
      if [ -z "$RESTY_BIN" ] && [ -x /usr/local/openresty/bin/resty ]; then
        RESTY_BIN="/usr/local/openresty/bin/resty"
      fi
      if [ -z "$RESTY_BIN" ] && [ -x /usr/local/openresty/luajit/bin/resty ]; then
        RESTY_BIN="/usr/local/openresty/luajit/bin/resty"
      fi
      if [ -z "$RESTY_BIN" ] && [ -x /usr/bin/resty ]; then
        RESTY_BIN="/usr/bin/resty"
      fi
      if [ -z "$RESTY_BIN" ]; then
        echo "resty not found in PATH or known locations" >&2
        echo "PATH=$PATH" >&2
        ls -la /usr/local/openresty/bin /usr/local/openresty/luajit/bin /usr/bin 2>/dev/null | sed -n "1,80p" >&2 || true
        exit 127
      fi

      LUACOV_BIN="$(find_luacov_bin || true)"
      if [ -z "$LUACOV_BIN" ]; then
        echo "luacov command not found in PATH or known locations (including LuaRocks trees)" >&2
        echo "PATH=$PATH" >&2
        ls -la /usr/local/bin /usr/bin /root/.luarocks/bin 2>/dev/null | sed -n "1,160p" >&2 || true
        ls -la /usr/local/lib/luarocks/rocks-5.1/luacov /usr/lib/luarocks/rocks-5.1/luacov /root/.luarocks/lib/luarocks/rocks-5.1/luacov 2>/dev/null | sed -n "1,160p" >&2 || true
        exit 127
      fi

      rm -f /tmp/luacov.stats.out /tmp/luacov.report.out
      cp /app/tests/unit/.luacov /tmp/.luacov
      LUACOV_CONFIG=/tmp/.luacov "$RESTY_BIN" /app/tests/unit/lua-runner.lua
      LUACOV_CONFIG=/tmp/.luacov "$LUACOV_BIN"
      cp /tmp/luacov.report.out /app/coverage/lua/luacov.report.out
    '
else
  "${DC[@]}" run --rm --no-deps \
    -v "$ROOT_DIR/tests:/app/tests" \
    openresty \
    sh -lc '
      RESTY_BIN="$(command -v resty || true)"
      if [ -z "$RESTY_BIN" ] && [ -x /usr/local/openresty/bin/resty ]; then
        RESTY_BIN="/usr/local/openresty/bin/resty"
      fi
      if [ -z "$RESTY_BIN" ] && [ -x /usr/local/openresty/luajit/bin/resty ]; then
        RESTY_BIN="/usr/local/openresty/luajit/bin/resty"
      fi
      if [ -z "$RESTY_BIN" ] && [ -x /usr/bin/resty ]; then
        RESTY_BIN="/usr/bin/resty"
      fi
      if [ -z "$RESTY_BIN" ]; then
        echo "resty not found in PATH or known locations" >&2
        echo "PATH=$PATH" >&2
        ls -la /usr/local/openresty/bin /usr/local/openresty/luajit/bin /usr/bin 2>/dev/null | sed -n "1,80p" >&2 || true
        exit 127
      fi
      "$RESTY_BIN" /app/tests/unit/lua-runner.lua
    '
fi
