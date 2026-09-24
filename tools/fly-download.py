#!/usr/bin/env python3
"""Download a private admin artifact through Fly's Machines API, without an SSH tunnel."""
import argparse
import base64
import json
import hashlib
import os
from pathlib import Path
import shlex
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--app', default='upload-video-api')
parser.add_argument('--machine', required=True)
parser.add_argument('remote')
parser.add_argument('local', type=Path)
args = parser.parse_args()
if not args.remote.startswith('/data/') or '..' in Path(args.remote).parts:
    raise SystemExit('Only /data/ admin artifacts may be downloaded')
os.umask(0o077)
# Create exclusively before retrieving so existing files are never overwritten.
with args.local.open('xb') as output:
    response = subprocess.run(['flyctl', 'machine', 'exec', args.machine,
        'base64 ' + shlex.quote(args.remote), '--app', args.app, '--json'], capture_output=True, text=True)
    if response.returncode != 0:
        raise SystemExit('Fly file download failed; check app and machine access')
    result = json.loads(response.stdout)
    if result.get('exit_code', 0) != 0 or result.get('stderr'):
        raise SystemExit('Remote file could not be read')
    data = base64.b64decode(result['stdout'])
    checksum = subprocess.run(['flyctl', 'machine', 'exec', args.machine,
        'sha256sum ' + shlex.quote(args.remote), '--app', args.app, '--json'], capture_output=True, text=True, check=True)
    expected = json.loads(checksum.stdout)['stdout'].split()[0]
    if hashlib.sha256(data).hexdigest() != expected:
        raise SystemExit('Download was truncated or changed; use SSH/SFTP for a larger file')
    output.write(data)
print('Saved', args.local)
