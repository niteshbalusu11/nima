#!/bin/sh
set -eu
# A fresh Fly volume is root-owned and hides the image's /data permissions.
# Fix only the database directory, then run the service as the unprivileged user.
if [ "$(id -u)" = 0 ]; then
    database_dir=$(dirname "${DATABASE_PATH:-/data/app.sqlite}")
    mkdir -p "$database_dir"
    chown app:app "$database_dir"
    chmod 700 "$database_dir"
    exec su-exec app:app uploadvideo "$@"
fi
exec uploadvideo "$@"
