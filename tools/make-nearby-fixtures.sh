#!/bin/bash
set -euo pipefail
umask 077
if [[ $# != 1 ]]; then
    echo "Usage: $0 new-output-directory" >&2
    exit 1
fi
mkdir "$1"
probe_output=$(cd "$1" && pwd)
probe_tmp=$(mktemp -d)
trap 'rm -rf "$probe_tmp"' EXIT
for name in a b c; do
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "$probe_tmp/$name.key" -out "$probe_tmp/$name.crt" \
        -days 7 -subj "/CN=Nearby probe $name/" -sha256 \
        -addext 'keyUsage=critical,digitalSignature' \
        -addext 'extendedKeyUsage=serverAuth,clientAuth' 2>/dev/null
    openssl rand -hex 24 > "$probe_tmp/$name.password"
    openssl pkcs12 -export -inkey "$probe_tmp/$name.key" -in "$probe_tmp/$name.crt" \
        -out "$probe_tmp/$name.p12" -passout "file:$probe_tmp/$name.password" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
    openssl x509 -in "$probe_tmp/$name.crt" -outform DER -out "$probe_tmp/$name.der"
done
python3 - "$probe_tmp" "$probe_output" <<'PY'
import base64
import json
from pathlib import Path
import sys
source, target = map(Path, sys.argv[1:])
for filename, own, peer in [('a', 'a', 'b'), ('b', 'b', 'a'),
                            ('unapproved-client', 'c', 'b'), ('wrong-server', 'a', 'c')]:
    encode = lambda name: base64.b64encode((source / name).read_bytes()).decode()
    (target / f'{filename}.nearby.json').write_text(json.dumps({
        'label': filename,
        'pkcs12': encode(f'{own}.p12'),
        'password': (source / f'{own}.password').read_text().strip(),
        'peerCertificate': encode(f'{peer}.der'),
    }))
PY
echo "Created private, disposable fixtures in $probe_output"
