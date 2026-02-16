#!/usr/bin/env bash
set -euo pipefail

curl -sS -X POST http://127.0.0.1:8080/_fn/reload | jq .
