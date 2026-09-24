#!/usr/bin/env python3
"""Redeem a printed invite for the retrieval helper; prompt avoids leaking secrets in shell history."""
import argparse
import getpass
import json
import os
import pathlib
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--api', default='http://127.0.0.1:8080')
parser.add_argument('--out', type=pathlib.Path, required=True)
args = parser.parse_args()
code = getpass.getpass('Invite QR contents: ').removeprefix('uploadvideo:invite:')
request = urllib.request.Request(args.api.rstrip('/') + '/enroll',
    data=json.dumps({'token': code}).encode(), headers={'Content-Type': 'application/json'}, method='POST')
# Reserve the destination before consuming a single-use invite.
fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        result = response.read()
    with os.fdopen(fd, 'wb') as output:
        output.write(result)
except BaseException:
    try:
        os.close(fd)
    except OSError:
        pass
    raise
print('Session saved to', args.out)
