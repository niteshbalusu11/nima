#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [storage-env-file]" >&2
    exit 1
fi
set -a
source "${1:-server/.env}"
set +a
cd server
TEST_RELAY_STORAGE=1 go test -race -count=1 -v -run '^TestRelayStorage$' ./...
