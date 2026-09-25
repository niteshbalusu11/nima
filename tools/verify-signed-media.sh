#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export SIGNED_MEDIA_GOLDEN="$PWD/server/testdata/signed-media-v1.json"
media_tmp=$(mktemp -d)
trap 'rm -rf "$media_tmp"' EXIT
swiftc -swift-version 6 -D DEBUG -parse-as-library \
    UploadVideo/API.swift UploadVideo/DeviceIdentity.swift UploadVideo/PeerStore.swift \
    UploadVideo/MediaRecords.swift UploadVideo/ReceivedMediaStore.swift UploadVideo/MediaStorageBudget.swift UploadVideo/UploadQueue.swift \
    UploadVideo/OwnerMediaRecords.swift tools/SignedMediaCheck.swift -o "$media_tmp/signed-media-check"
cd server
SIGNED_MEDIA_PROBE="$media_tmp/signed-media-check" go test -race -count=1 -v -run '^Test(SwiftSignedMedia|MediaRecord)' ./...
