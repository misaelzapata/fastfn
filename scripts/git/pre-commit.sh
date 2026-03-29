#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN="${FASTFN_PRECOMMIT_DRY_RUN:-0}"
FULL_MODE="${FASTFN_PRECOMMIT_FULL:-0}"
PYTHON_BIN="python3"

if [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
  export PATH="$ROOT_DIR/.venv/bin:$PATH"
  PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
fi

log() {
  printf '[pre-commit] %s\n' "$1"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

run_here() {
  local timeout_seconds="$1"
  shift
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run (${timeout_seconds}s): $*"
    return 0
  fi
  if has_cmd timeout; then
    timeout "${timeout_seconds}s" "$@"
    return
  fi
  "$@"
}

run_in_dir() {
  local timeout_seconds="$1"
  local dir="$2"
  shift 2
  if [[ "$DRY_RUN" == "1" ]]; then
    log "dry-run (${timeout_seconds}s) in ${dir}: $*"
    return 0
  fi
  if has_cmd timeout; then
    (
      cd "$dir"
      timeout "${timeout_seconds}s" "$@"
    )
    return
  fi
  (
    cd "$dir"
    "$@"
  )
}

append_unique() {
  local item="$1"
  local array_name="$2"
  local existing
  declare -n arr="$array_name"
  for existing in "${arr[@]}"; do
    if [[ "$existing" == "$item" ]]; then
      return 0
    fi
  done
  arr+=("$item")
}

path_matches() {
  local path="$1"
  local pattern="$2"
  [[ "$path" =~ $pattern ]]
}

staged_matches() {
  local pattern="$1"
  local path
  for path in "${STAGED_FILES[@]}"; do
    if path_matches "$path" "$pattern"; then
      return 0
    fi
  done
  return 1
}

ensure_staged_files() {
  mapfile -t STAGED_FILES < <(git diff --cached --name-only --diff-filter=ACMR)
  if [[ "${#STAGED_FILES[@]}" -eq 0 ]]; then
    log "No staged files; skipping hook"
    exit 0
  fi
}

check_embedded_sync() {
  local path src embedded pair_key drift=0
  declare -A checked_pairs=()

  for path in "${STAGED_FILES[@]}"; do
    src=""
    embedded=""
    case "$path" in
      openresty/*)
        src="$path"
        embedded="cli/embed/runtime/openresty/${path#openresty/}"
        ;;
      cli/embed/runtime/openresty/*)
        embedded="$path"
        src="openresty/${path#cli/embed/runtime/openresty/}"
        ;;
      srv/fn/runtimes/*.py|srv/fn/runtimes/*.js)
        src="$path"
        embedded="cli/embed/runtime/$path"
        ;;
      cli/embed/runtime/srv/fn/runtimes/*.py|cli/embed/runtime/srv/fn/runtimes/*.js)
        embedded="$path"
        src="${path#cli/embed/runtime/}"
        ;;
      *)
        continue
        ;;
    esac

    if [[ ! -f "$src" || ! -f "$embedded" ]]; then
      continue
    fi

    pair_key="${src}::${embedded}"
    if [[ -n "${checked_pairs[$pair_key]:-}" ]]; then
      continue
    fi
    checked_pairs["$pair_key"]=1

    if ! diff -q "$src" "$embedded" >/dev/null 2>&1; then
      log "DRIFT: $src != $embedded"
      drift=1
    fi
  done

  if [[ "$drift" -ne 0 ]]; then
    log "FAILED: embedded files out of sync"
    exit 1
  fi
}

run_go_checks() {
  local path dir pkg
  declare -a go_packages=()

  if ! staged_matches '^cli/.*\.go$|^cli/go\.(mod|sum)$'; then
    return 0
  fi

  log "Running Go checks..."

  if staged_matches '^cli/go\.(mod|sum)$'; then
    run_here 900 "$ROOT_DIR/cli/test-go.sh" -timeout 300s -count=1 ./...
    return 0
  fi

  for path in "${STAGED_FILES[@]}"; do
    if ! path_matches "$path" '^cli/.*\.go$'; then
      continue
    fi
    dir="$(dirname "$path")"
    if [[ "$dir" == "cli" ]]; then
      pkg="."
    else
      pkg="./${dir#cli/}"
    fi
    append_unique "$pkg" go_packages
  done

  for pkg in "${go_packages[@]}"; do
    run_here 420 "$ROOT_DIR/cli/test-go.sh" -timeout 300s -count=1 "$pkg"
  done
}

run_python_checks() {
  local path
  declare -a pytest_targets=()

  if ! staged_matches '^tests/unit/python/.*\.py$|^srv/fn/runtimes/.*\.py$|^cli/embed/runtime/srv/fn/runtimes/.*\.py$'; then
    return 0
  fi

  log "Running Python checks..."

  for path in "${STAGED_FILES[@]}"; do
    if path_matches "$path" '^tests/unit/python/.*\.py$'; then
      append_unique "$path" pytest_targets
    fi
  done

  if [[ "${#pytest_targets[@]}" -eq 0 ]] || staged_matches '^srv/fn/runtimes/.*\.py$|^cli/embed/runtime/srv/fn/runtimes/.*\.py$|^tests/unit/python/conftest\.py$'; then
    run_here 600 "$PYTHON_BIN" -m pytest tests/unit/python/ -q \
      -W error::RuntimeWarning \
      -W error::pytest.PytestUnraisableExceptionWarning
    return 0
  fi

  run_here 600 "$PYTHON_BIN" -m pytest -q "${pytest_targets[@]}"
}

run_node_checks() {
  local path
  declare -a jest_targets=()
  declare -a related_sources=()
  local need_node_daemon_test=0
  local need_node_daemon_adapters_test=0

  if ! staged_matches '^tests/unit/node/.*\.(js|json)$|^srv/fn/runtimes/.*\.js$|^cli/embed/runtime/srv/fn/runtimes/.*\.js$|^examples/functions/node/.*\.(js|json)$|^package(-lock)?\.json$|^jest\.config\.js$'; then
    return 0
  fi

  log "Running Node checks..."

  for path in "${STAGED_FILES[@]}"; do
    if path_matches "$path" '^tests/unit/node/.*\.test\.js$'; then
      append_unique "$path" jest_targets
      continue
    fi

    if path_matches "$path" '^tests/unit/node/helpers\.js$|^package(-lock)?\.json$|^jest\.config\.js$'; then
      append_unique "tests/unit/node/" jest_targets
      continue
    fi

    if path_matches "$path" '^srv/fn/runtimes/node-daemon\.js$|^cli/embed/runtime/srv/fn/runtimes/node-daemon\.js$'; then
      need_node_daemon_test=1
      need_node_daemon_adapters_test=1
      continue
    fi

    if path_matches "$path" '^examples/functions/node/.*\.(js|json)$'; then
      append_unique "$path" related_sources
      continue
    fi
  done

  declare -a general_jest_targets=()
  local need_full_node_suite=0
  for path in "${jest_targets[@]}"; do
    case "$path" in
      tests/unit/node/)
        need_full_node_suite=1
        ;;
      tests/unit/node/node-daemon.test.js)
        need_node_daemon_test=1
        ;;
      tests/unit/node/node-daemon-adapters.test.js)
        need_node_daemon_adapters_test=1
        ;;
      *)
        append_unique "$path" general_jest_targets
        ;;
    esac
  done

  if [[ "$need_full_node_suite" -eq 1 ]]; then
    run_here 900 bash "$ROOT_DIR/scripts/ci/run_node_unit.sh"
  fi

  if [[ "${#general_jest_targets[@]}" -gt 0 ]]; then
    run_here 900 bash "$ROOT_DIR/scripts/ci/run_jest.sh" --runInBand --bail --no-coverage "${general_jest_targets[@]}"
  fi

  if [[ "$need_node_daemon_test" -eq 1 ]]; then
    run_here 900 bash "$ROOT_DIR/scripts/ci/run_jest.sh" \
      --runInBand --bail --no-coverage --silent tests/unit/node/node-daemon.test.js \
      --testNamePattern 'sanitizeWorkerEnv|internal helper guards|root assets directory'

    run_here 900 bash "$ROOT_DIR/scripts/ci/run_jest.sh" \
      --runInBand --bail --no-coverage --silent tests/unit/node/node-daemon.test.js \
      --testNamePattern 'handleRequest validation|unknown function|invalid function names|collectHandlerPaths|magic responses|contract responses|csv responses|handler and adapter config|handleRequest resolves explicit functions through fn_source_dir|lambda adapter|cloudflare adapter|entrypoint discovery|hot reload|env features|misc features'

    run_here 900 bash "$ROOT_DIR/scripts/ci/run_jest.sh" \
      --runInBand --bail --no-coverage --silent tests/unit/node/node-daemon.test.js \
      --testNamePattern 'deps isolation between functions'

    run_here 900 bash "$ROOT_DIR/scripts/ci/run_jest.sh" \
      --runInBand --bail --no-coverage --silent tests/unit/node/node-daemon.test.js \
      --testNamePattern 'comprehensive coverage'
  fi

  if [[ "$need_node_daemon_adapters_test" -eq 1 ]]; then
    run_here 900 bash "$ROOT_DIR/scripts/ci/run_jest.sh" --runInBand --bail --no-coverage --silent tests/unit/node/node-daemon-adapters.test.js
  fi

  if [[ "${#related_sources[@]}" -gt 0 ]]; then
    run_here 900 bash "$ROOT_DIR/scripts/ci/run_jest.sh" --runInBand --bail --no-coverage --findRelatedTests --passWithNoTests "${related_sources[@]}"
  fi
}

run_lua_checks() {
  if ! staged_matches '^openresty/|^cli/embed/runtime/openresty/|^tests/unit/lua-runner\.lua$'; then
    return 0
  fi

  log "Running Lua checks..."
  if has_cmd docker && docker info >/dev/null 2>&1; then
    run_here 1200 env LUA_COVERAGE=0 bash cli/test-lua.sh
    return 0
  fi

  log "SKIPPED: Lua checks (Docker not available)"
}

run_shell_checks() {
  local path
  declare -a shell_targets=()

  if ! staged_matches '^tests/integration/.*\.sh$|^cli/test-all\.sh$|^scripts/ci/.*\.sh$'; then
    return 0
  fi

  log "Running shell syntax checks..."
  for path in "${STAGED_FILES[@]}"; do
    if path_matches "$path" '^tests/integration/.*\.sh$|^cli/test-all\.sh$|^scripts/ci/.*\.sh$'; then
      append_unique "$path" shell_targets
    fi
  done

  if [[ "${#shell_targets[@]}" -gt 0 ]]; then
    run_here 120 bash -n "${shell_targets[@]}"
  fi
}

run_visual_manifest_check() {
  if [[ ! -f "scripts/docs/visual_manifest.py" ]]; then
    return 0
  fi
  if ! staged_matches '^docs/|^scripts/docs/visual_manifest\.py$'; then
    return 0
  fi

  log "Checking visual manifest..."
  run_here 300 "$PYTHON_BIN" scripts/docs/visual_manifest.py verify
}

run_full_suite() {
  log "Running full suite (FASTFN_PRECOMMIT_FULL=1)..."
  run_here 3600 env RUN_UI_E2E=0 bash scripts/ci/test-pipeline.sh
}

main() {
  ensure_staged_files

  log "Fast incremental pre-commit"
  check_embedded_sync

  if [[ "$FULL_MODE" == "1" ]]; then
    run_full_suite
    log "All checks passed"
    return 0
  fi

  run_go_checks
  run_python_checks
  run_node_checks
  run_lua_checks
  run_shell_checks
  run_visual_manifest_check

  log "All incremental checks passed"
  log "Pre-push runs the full suite and blocks broken pushes"
  log "Need the old full gate now? Run: FASTFN_PRECOMMIT_FULL=1 .git/hooks/pre-commit"
}

main "$@"
