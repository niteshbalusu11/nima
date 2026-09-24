#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
flyctl config validate --config server/fly.toml
(cd server && go test -race ./...)
# One database volume; never create Fly's automatic spare Machine.
exec flyctl deploy . --config server/fly.toml --ha=false --local-only "$@"
