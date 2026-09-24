#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 6 -D DEBUG -parse-as-library UploadVideo/API.swift UploadVideo/UploadQueue.swift tools/QueueProbe.swift -o "$task_tmp/queue-probe"
"$task_tmp/queue-probe"
swiftc -swift-version 6 -D DEBUG -parse-as-library UploadVideo/API.swift UploadVideo/UploadQueue.swift UploadVideo/SegmentWriter.swift tools/MediaProbe.swift -o "$task_tmp/media-probe"
cd server
set -a
source .env
set +a
TEST_S3=1 MEDIA_PROBE="$task_tmp/media-probe" go test -race -v ./...
