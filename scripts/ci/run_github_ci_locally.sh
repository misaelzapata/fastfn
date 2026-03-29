#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
JOB="${1:-all}"
UBUNTU_IMAGE="${FASTFN_GITHUB_CI_UBUNTU_IMAGE:-ubuntu:24.04}"
GO_IMAGE="${FASTFN_GITHUB_CI_GO_IMAGE:-golang:1.21-bookworm}"
KEEP_WORKDIR="${FASTFN_GITHUB_CI_KEEP_WORKDIR:-0}"

usage() {
  cat <<'EOF'
Usage: scripts/ci/run_github_ci_locally.sh [cli|unit|docs|e2e|all]

Runs GitHub CI-like jobs inside disposable containers against a temporary copy
of the current workspace, so local toolchains and generated artifacts do not
leak into the validation.

Environment:
  FASTFN_GITHUB_CI_UBUNTU_IMAGE   Override the Ubuntu image for unit/docs/e2e.
  FASTFN_GITHUB_CI_GO_IMAGE       Override the Go image for the cli job.
  FASTFN_GITHUB_CI_KEEP_WORKDIR   Keep the temporary workspace (1 to keep).
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

cleanup_workdir() {
  local dir="$1"
  if [[ "$KEEP_WORKDIR" == "1" ]]; then
    echo "[github-ci-local] keeping workspace: $dir"
    return
  fi
  if rm -rf "$dir" 2>/dev/null; then
    return
  fi
  docker run --rm \
    -v "$dir:/work" \
    alpine:3.20 \
    sh -c "chown -R $(id -u):$(id -g) /work" >/dev/null
  rm -rf "$dir"
}

copy_workspace() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/fastfn-github-ci.XXXXXX")"
  rsync -a \
    --exclude='.git' \
    --exclude='.venv' \
    --exclude='node_modules' \
    --exclude='coverage' \
    --exclude='playwright-report' \
    --exclude='tests/results' \
    --exclude='.pytest_cache' \
    --exclude='.coverage' \
    --exclude='cli/.coverage' \
    "$ROOT_DIR"/ "$dir"/
  printf '%s\n' "$dir"
}

write_script() {
  local workdir="$1"
  local name="$2"
  shift 2
  local target="$workdir/.github-ci-local-${name}.sh"
  cat >"$target"
  chmod +x "$target"
  printf '%s\n' "$target"
}

run_container_script() {
  local image="$1"
  local workdir="$2"
  local script_path="$3"
  shift 3
  docker run --rm -t \
    --network host \
    -v "$workdir:/work" \
    -w /work \
    -e CI=true \
    -e FORCE_JAVASCRIPT_ACTIONS_TO_NODE24=true \
    "$@" \
    "$image" \
    bash "/work/$(basename "$script_path")"
}

run_cli_job() {
  local workdir="$1"
  local script_path
  script_path="$(write_script "$workdir" cli <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends bash ca-certificates git curl
cd /work/cli
go mod download
cd /work
COVERAGE_MIN_GO=100 ./cli/coverage-go.sh
cd /work/cli
go build -o ../bin/fastfn
EOF
)"
  run_container_script "$GO_IMAGE" "$workdir" "$script_path"
}

run_docs_job() {
  local workdir="$1"
  local script_path
  script_path="$(write_script "$workdir" docs <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends bash python3 python3-pip python3-venv
python3 -m venv /tmp/fastfn-docs-venv
. /tmp/fastfn-docs-venv/bin/activate
python -m pip install --upgrade pip mkdocs-material
python3 scripts/ci/check_host_path_leaks.py
python3 scripts/docs/visual_manifest.py verify
python3 scripts/docs/check_path_neutrality.py
python3 scripts/docs/check_doc_consistency.py
python -m mkdocs build --strict
python3 scripts/docs/check_doc_links.py
EOF
)"
  run_container_script "$UBUNTU_IMAGE" "$workdir" "$script_path"
}

run_unit_job() {
  local workdir="$1"
  local script_path
  script_path="$(write_script "$workdir" unit <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  bash \
  ca-certificates \
  curl \
  docker.io \
  docker-compose-v2 \
  gnupg \
  lsb-release \
  php-cli \
  php-xdebug \
  python3 \
  python3-pip \
  python3-venv \
  ripgrep

mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y --no-install-recommends nodejs

codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
mkdir -p /usr/share/keyrings
curl -fsSL https://openresty.org/package/pubkey.gpg \
  | gpg --dearmor -o /usr/share/keyrings/openresty.gpg
echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/ubuntu ${codename} main" \
  > /etc/apt/sources.list.d/openresty.list
apt-get update
apt-get install -y --no-install-recommends openresty

python3 -m venv /tmp/fastfn-unit-venv
. /tmp/fastfn-unit-venv/bin/activate
python -m pip install --upgrade pip
python -m pip install coverage pytest
npm install -g c8

cd /work
python3 scripts/ci/check_host_path_leaks.py
npm ci --no-fund --no-audit
chmod +x cli/coverage.sh

export COVERAGE_MIN_PYTHON=100
export COVERAGE_MIN_PYTHON_FILE=100
export COVERAGE_MIN_NODE=100
export COVERAGE_MIN_NODE_FILE=100
export COVERAGE_MIN_COMBINED=100
export COVERAGE_MIN_LUA=100
export COVERAGE_MIN_LUA_FILE=100
export COVERAGE_ENFORCE_LUA=1
export COVERAGE_ENFORCE_LUA_PER_FILE=1
export COVERAGE_MIN_PHP=100
export COVERAGE_MIN_PHP_FILE=100
export COVERAGE_MIN_RUST=100
export COVERAGE_MIN_RUST_FILE=100

./cli/coverage.sh
bash tests/unit/test-sdks.sh
EOF
)"
  if [[ ! -S /var/run/docker.sock ]]; then
    echo "error: unit job reproduction requires /var/run/docker.sock" >&2
    exit 1
  fi
  run_container_script \
    "$UBUNTU_IMAGE" \
    "$workdir" \
    "$script_path" \
    -v /var/run/docker.sock:/var/run/docker.sock
}

run_e2e_job() {
  local workdir="$1"
  local script_path
  script_path="$(write_script "$workdir" e2e <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  bash \
  ca-certificates \
  curl \
  docker.io \
  docker-compose-v2 \
  gnupg \
  lsb-release \
  python3 \
  python3-pip \
  python3-venv

mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y --no-install-recommends nodejs

codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
mkdir -p /usr/share/keyrings
curl -fsSL https://openresty.org/package/pubkey.gpg \
  | gpg --dearmor -o /usr/share/keyrings/openresty.gpg
echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/ubuntu ${codename} main" \
  > /etc/apt/sources.list.d/openresty.list
apt-get update
apt-get install -y --no-install-recommends openresty

python3 -m venv /tmp/fastfn-e2e-venv
. /tmp/fastfn-e2e-venv/bin/activate
python -m pip install --upgrade pip

cd /work
npm install --no-fund --no-audit
npx playwright install --with-deps chromium

export FN_REQUIRE_NATIVE_DEPS=1
export FASTFN_PLAYWRIGHT_INSTALL_BROWSERS=0
sh ./scripts/ci/test-pipeline.sh
EOF
)"
  if [[ ! -S /var/run/docker.sock ]]; then
    echo "error: e2e job reproduction requires /var/run/docker.sock" >&2
    exit 1
  fi
  run_container_script \
    "$UBUNTU_IMAGE" \
    "$workdir" \
    "$script_path" \
    -v /var/run/docker.sock:/var/run/docker.sock
}

run_job() {
  local job="$1"
  local workdir
  local status=0
  workdir="$(copy_workspace)"
  echo "[github-ci-local] job=$job workspace=$workdir"
  case "$job" in
    cli) run_cli_job "$workdir" || status=$? ;;
    docs) run_docs_job "$workdir" || status=$? ;;
    unit) run_unit_job "$workdir" || status=$? ;;
    e2e) run_e2e_job "$workdir" || status=$? ;;
    *)
      cleanup_workdir "$workdir"
      echo "error: unsupported job: $job" >&2
      exit 1
      ;;
  esac
  cleanup_workdir "$workdir"
  return "$status"
}

require_cmd docker
require_cmd rsync

case "$JOB" in
  cli|docs|unit|e2e)
    run_job "$JOB"
    ;;
  all)
    run_job cli
    run_job unit
    run_job docs
    run_job e2e
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
