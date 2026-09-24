#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../server"
flyctl config validate
go test ./...
# One database volume; never create Fly's automatic spare Machine.
exec flyctl deploy --ha=false --local-only "$@"
