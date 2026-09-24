#!/usr/bin/env python3
"""Check a deployed private API using disposable invites and synthetic media only."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=['enroll', 'verify', 'persistence'])
parser.add_argument('--api', required=True)
parser.add_argument('--state', type=Path, required=True)
parser.add_argument('--invite', type=Path)
args = parser.parse_args()
os.umask(0o077)
args.state.mkdir(parents=True, exist_ok=True, mode=0o700)
session_path = args.state / 'session.json'

def call(method, path, body=None, token=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(args.api.rstrip('/') + path, method=method, headers=headers,
        data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, {}

if args.action == 'enroll':
    if not args.invite or session_path.exists():
        raise SystemExit('Supply a fresh invite and a new state directory')
    invite = args.invite.read_text().strip().removeprefix('uploadvideo:invite:')
    status, session = call('POST', '/enroll', {'token': invite})
    assert status == 201, f'enrollment: {status}'
    assert set(session) == {'token', 'account_id'}, 'unexpected enrollment response; sessions have no expiry'
    session_path.write_text(json.dumps(session))
    status, _ = call('POST', '/enroll', {'token': invite})
    assert status == 401, f'invite reuse accepted: {status}'
    status, _ = call('PATCH', '/me', {'name': 'Deployment check', 'email': '', 'signal_username': ''}, session['token'])
    assert status == 200, f'profile save: {status}'
    print('PASS: fresh invite redeemed once, session stored privately, optional profile saved')
    raise SystemExit

session = json.loads(session_path.read_text())
token = session['token']
status, profile = call('GET', '/me', token=token)
assert status == 200 and profile['id'] == session['account_id'] and profile['name'] == 'Deployment check', 'session/profile lost'
status, _ = call('GET', '/captures')
assert status == 401, 'anonymous API access allowed'
captures = json.loads((args.state / 'captures.json').read_text())
for capture_id in captures.values():
    status, capture = call('GET', '/captures/' + capture_id, token=token)
    assert status == 200 and any(o['acknowledged'] for o in capture['objects']), 'media metadata lost'
if args.action == 'persistence':
    print('PASS: original session, profile, and uploaded media survived restart')
    raise SystemExit

# Reuse a real synthetic JPEG from MediaProbe; reserve a new capture and deliberately omit /ack.
photo = next(folder / 'media' for folder in (args.state / 'queue').iterdir()
             if json.loads((folder / 'item.json').read_text())['kind'] == 'photo')
payload = photo.read_bytes()
capture_id = str(uuid.uuid4())
status, _ = call('PUT', '/captures/' + capture_id, {'kind': 'photo'}, token)
assert status == 200, f'create capture: {status}'
reservation = {'sequence': 0, 'kind': 'photo', 'sha256': hashlib.sha256(payload).hexdigest(),
               'md5': base64.b64encode(hashlib.md5(payload).digest()).decode(),
               'size': len(payload), 'duration': 0, 'start_time': 0}
status, signed = call('POST', '/captures/' + capture_id + '/objects/reserve', reservation, token)
assert status == 200, f'reserve object: {status}'

def put():
    request = urllib.request.Request(signed['url'], data=payload, headers=signed['headers'], method='PUT')
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code

assert put() == 200, 'signed Tigris upload failed'
assert put() == 412, 'conditional upload allowed overwrite'
status, recovered = call('GET', '/captures/' + capture_id, token=token)
assert status == 200 and recovered['objects'][0]['acknowledged'], 'unacknowledged upload was not recovered'
obj = recovered['objects'][0]
with urllib.request.urlopen(obj['url'], timeout=60) as response:
    assert response.read() == payload, 'download differs'
unsigned = urllib.parse.urlsplit(obj['url'])._replace(query='').geturl()
try:
    with urllib.request.urlopen(unsigned, timeout=30) as response:
        raise AssertionError('Tigris object is publicly readable')
except urllib.error.HTTPError as error:
    assert error.code in (401, 403), f'unexpected private read status: {error.code}'
print('PASS: real Tigris PUT/GET, overwrite rejection, private object access, lost-ack recovery')
