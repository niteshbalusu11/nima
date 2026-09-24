#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../server"
if [[ ! -f .env ]]; then
    python3 - <<'PY'
from pathlib import Path
import secrets
path = Path('.env')
path.write_text(Path('.env.example').read_text()
    .replace('replace-with-random-local-access-key', secrets.token_hex(12))
    .replace('replace-with-random-local-secret', secrets.token_hex(32)))
path.chmod(0o600)
PY
fi
set -a
source .env
set +a
if [[ "${APP_ENV:-}" != development ]]; then
    echo "start-local.sh requires APP_ENV=development" >&2
    exit 1
fi
docker compose up -d
for attempt in {1..30}; do
    if curl --silent --fail "${S3_ENDPOINT}/health" > /dev/null; then break; fi
    sleep 1
done
go build -o uploadvideo .
./uploadvideo init-bucket
exec ./uploadvideo serve
