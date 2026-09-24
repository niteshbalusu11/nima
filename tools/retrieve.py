#!/usr/bin/env python3
"""Download your own captures. Credentials are read from a protected session JSON file."""
import argparse
import hashlib
import json
import pathlib
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--api', default='http://127.0.0.1:8080')
parser.add_argument('--session', type=pathlib.Path, required=True, help='session JSON obtained using a fresh invite for the same account')
parser.add_argument('--capture', help='omit to list captures')
parser.add_argument('--out', type=pathlib.Path, default=pathlib.Path('retrieved'))
args = parser.parse_args()
token = json.loads(args.session.read_text())['token']

def api(path):
    request = urllib.request.Request(args.api.rstrip('/') + path, headers={'Authorization': 'Bearer ' + token})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)

if not args.capture:
    after = ''
    while True:
        page = api('/captures?after=' + urllib.parse.quote(after))['captures']
        for capture in page:
            print(capture['id'], capture['kind'], capture['created_at'])
        if len(page) < 100:
            break
        after = page[-1]['id']
    raise SystemExit

args.out.mkdir(parents=True, exist_ok=True, mode=0o700)
objects = []
after = -1
kind = None
while True:
    page = api('/captures/' + urllib.parse.quote(args.capture, safe='') + '?after=' + str(after))
    kind = page['kind']
    for obj in page['objects']:
        if not obj['acknowledged']:
            print('Missing:', obj['sequence'])
            objects.append((obj, None))
            continue
        # Download each page before its short-lived URLs expire.
        with urllib.request.urlopen(obj['url'], timeout=60) as response:
            data = response.read(obj['size'] + 1)
        if len(data) != obj['size'] or hashlib.sha256(data).hexdigest() != obj['sha256']:
            raise SystemExit('Download digest mismatch')
        name = f"{obj['sequence']:06d}." + ('jpg' if kind == 'photo' else 'mp4' if obj['kind'] == 'init' else 'm4s')
        path = args.out / name
        path.write_bytes(data)
        path.chmod(0o600)
        objects.append((obj, path))
    if len(page['objects']) < 50:
        break
    after = page['objects'][-1]['sequence']

if kind == 'video':
    initialization = next((path for obj, path in objects if obj['kind'] == 'init' and path), None)
    if initialization is None:
        raise SystemExit('Initialization segment is missing; retain the downloaded fragments')
    # Split at missing sequences, rather than silently representing gaps as continuous capture.
    runs = []
    run = []
    previous = 0
    for obj, path in objects:
        if obj['kind'] != 'media':
            continue
        if not path or obj['sequence'] != previous + 1:
            if run:
                runs.append(run)
                run = []
            print('Video gap before sequence', obj['sequence'])
        if path:
            run.append(path)
        previous = obj['sequence']
    if run:
        runs.append(run)
    for index, paths in enumerate(runs):
        result = args.out / f'video-{index + 1}.mp4'
        with result.open('wb') as output:
            output.write(initialization.read_bytes())
            for path in paths:
                output.write(path.read_bytes())
        result.chmod(0o600)
        print(result)
else:
    for _, path in objects:
        if path:
            print(path)
