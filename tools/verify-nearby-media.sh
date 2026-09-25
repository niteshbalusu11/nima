#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
nearby_build="$PWD/.build/nearby-media"
mkdir -p "$nearby_build/Sources/Check"
rm -f "$nearby_build/Sources/Check/"*.swift
cp UploadVideo/{API,DeviceIdentity,NearbyPermission,NearbyPairing,PeerStore,MediaRecords,MediaStorageBudget,UploadQueue,OwnerMediaRecords,ReceivedMediaStore,UploadSlots,RelayUploadWorker,NearbyChannel,NearbyTransfer,LivePlayback,SegmentWriter,PhotoLibrary,CaptureLibrary}.swift \
   tools/{MediaProbe,NearbyMediaCheck,LoopbackMediaReceiver}.swift "$nearby_build/Sources/Check/"
python3 - "$nearby_build/Package.swift" <<'PY'
import json, pathlib, sys
pins = json.loads(pathlib.Path('UploadVideo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
deps = ',\n'.join('.package(url: ' + json.dumps(p['location']) + ', exact: ' + json.dumps(p['state']['version']) + ')' for p in pins)
pathlib.Path(sys.argv[1]).write_text('''// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "NearbyMediaCheck", platforms: [.macOS(.v15)],
    dependencies: [\n''' + deps + '''\n],
    targets: [.executableTarget(name: "Check", dependencies: [.product(name: "X509", package: "swift-certificates")],
        swiftSettings: [.define("DEBUG"), .define("NEARBY_MEDIA_CHECK")])])
''')
PY
swift build --package-path "$nearby_build" --product Check
nearby_binary=$(swift build --package-path "$nearby_build" --show-bin-path)
cd server
set -a
source .env
set +a
TEST_S3=1 NEARBY_MEDIA_PROBE="$nearby_binary/Check" go test -race -count=1 -v -run '^TestSwiftNearbyMediaRecovery$' ./...
