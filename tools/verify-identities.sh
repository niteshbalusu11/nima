#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
identity_tmp=$(mktemp -d)
trap 'rm -rf "$identity_tmp"' EXIT
swiftc -swift-version 6 -D DEBUG -parse-as-library \
    UploadVideo/API.swift UploadVideo/DeviceIdentity.swift tools/DeviceIdentityCheck.swift -o "$identity_tmp/identity-check"
cd server
IDENTITY_PROBE="$identity_tmp/identity-check" go test -race -count=1 -v -run '^Test(Device|Peer|SwiftDevice)' ./...
