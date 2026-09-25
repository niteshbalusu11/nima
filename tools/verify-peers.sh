#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
peer_tmp=$(mktemp -d)
trap 'rm -rf "$peer_tmp"' EXIT
swiftc -swift-version 6 -D DEBUG -parse-as-library \
    UploadVideo/API.swift UploadVideo/DeviceIdentity.swift UploadVideo/NearbyPermission.swift UploadVideo/PeerStore.swift \
    tools/PairingFixture.swift tools/PeerCheck.swift -o "$peer_tmp/peer-check"
cd server
PEER_PROBE="$peer_tmp/peer-check" go test -race -count=1 -v -run '^Test(Peer|SwiftPeer)' ./...
