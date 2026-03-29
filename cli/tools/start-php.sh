#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

export FN_PHP_SOCKET="${FN_PHP_SOCKET:-/tmp/fastfn/fn-php.sock}"
exec php "$ROOT_DIR/srv/fn/runtimes/php-daemon.php"
