#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Compile the real app sources with exactly the app's resolved Apple packages.
# Build products stay in the ignored .build directory; sessions/caches are disposable Go fixtures.
registered_build="$PWD/.build/registered-nearby"
mkdir -p "$registered_build/Sources/Check"
cp UploadVideo/API.swift UploadVideo/DeviceIdentity.swift UploadVideo/PeerStore.swift \
   UploadVideo/NearbyProbe.swift tools/PeerCheck.swift tools/RegisteredNearbyCheck.swift "$registered_build/Sources/Check/"
python3 - "$registered_build/Package.swift" <<'PY'
import json, pathlib, sys
pins = json.loads(pathlib.Path('UploadVideo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
deps = ',\n'.join('.package(url: ' + json.dumps(p['location']) + ', exact: ' + json.dumps(p['state']['version']) + ')' for p in pins)
pathlib.Path(sys.argv[1]).write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "RegisteredNearbyCheck", platforms: [.macOS(.v15)],
    dependencies: [\n''' + deps + '''\n],
    targets: [.executableTarget(name: "Check", dependencies: [.product(name: "X509", package: "swift-certificates")],
        swiftSettings: [.define("DEBUG")])])
''')
PY
swift build --package-path "$registered_build" --product Check
registered_binary=$(swift build --package-path "$registered_build" --show-bin-path)
cd server
PEER_PROBE="$registered_binary/Check" go test -race -count=1 -v -run '^TestSwiftPeerApprovals$' ./...
