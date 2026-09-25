#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
probe_tmp=$(mktemp -d)
trap 'rm -rf "$probe_tmp"' EXIT
./tools/make-nearby-fixtures.sh "$probe_tmp/identities"
swiftc -swift-version 6 -D DEBUG -parse-as-library \
    UploadVideo/API.swift UploadVideo/DeviceIdentity.swift UploadVideo/NearbyPermission.swift UploadVideo/PeerStore.swift \
    UploadVideo/NearbyProbe.swift tools/NearbyCheck.swift -o "$probe_tmp/nearby-probe"
"$probe_tmp/nearby-probe" "$probe_tmp/identities"
