#!/bin/bash
set -e

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "Testing SDKs..."

# 1. Python SDK
# Need to ensure the python path includes the root so sdk.python can be imported
export PYTHONPATH="$ROOT"
if python3 -c "from sdk.python.fastfn.types import Request; print('Python SDK: OK')"; then
    :
else
    echo "Python SDK failed"
    exit 1
fi

# 2. PHP SDK
# Check if the class can be loaded
if command -v php >/dev/null; then
    if php -r "require '$ROOT/sdk/php/FastFn.php'; if(class_exists('FastFn\Request')) echo 'PHP SDK: OK\n'; else exit(1);"; then
        :
    else
        echo "PHP SDK failed"
        exit 1
    fi
else
    echo "PHP SDK: skipped (php not found)"
fi

# 3. Rust SDK
# Check if cargo check works
if command -v cargo >/dev/null; then
    cd "$ROOT/sdk/rust"
    if cargo check --quiet; then
        echo "Rust SDK: OK"
    else
        echo "Rust SDK failed"
        exit 1
    fi
else
    echo "Rust SDK: skipped (cargo not found)"
fi

# 4. JS SDK
# Just verify the check file exists for now as it is type definitions only
if [ -f "$ROOT/sdk/js/index.d.ts" ]; then
    echo "JS SDK: OK"
else
    echo "JS SDK failed (missing index.d.ts)"
    exit 1
fi
