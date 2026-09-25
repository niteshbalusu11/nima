#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [booted-simulator-udid]" >&2
    exit 1
fi
cd "$(dirname "$0")/.."
identity_tmp=$(mktemp -d)
export IDENTITY_CHECK_SIMULATOR="${1:-booted}"
export IDENTITY_CHECK_BUNDLE="dev.witness.identity-check.p$(uuidgen | tr '[:upper:]' '[:lower:]')"
cleanup() {
    xcrun simctl launch --terminate-running-process --console "$IDENTITY_CHECK_SIMULATOR" "$IDENTITY_CHECK_BUNDLE" cleanup >/dev/null 2>&1 || true
    xcrun simctl uninstall "$IDENTITY_CHECK_SIMULATOR" "$IDENTITY_CHECK_BUNDLE" >/dev/null 2>&1 || true
    rm -rf "$identity_tmp"
}
trap cleanup EXIT
mkdir "$identity_tmp/IdentityCheck.app"
python3 - "$identity_tmp" "$IDENTITY_CHECK_BUNDLE" <<'PY'
from pathlib import Path
import plistlib
import sys
root, bundle = Path(sys.argv[1]), sys.argv[2]
with (root / 'IdentityCheck.app/Info.plist').open('wb') as f:
    plistlib.dump({'CFBundleIdentifier': bundle, 'CFBundleExecutable': 'IdentityCheck',
                  'CFBundleName': 'IdentityCheck', 'CFBundleVersion': '1',
                  'CFBundleShortVersionString': '1', 'CFBundlePackageType': 'APPL',
                  'CFBundleSupportedPlatforms': ['iPhoneSimulator'], 'LSRequiresIPhoneOS': True,
                  'MinimumOSVersion': '17.0', 'UIDeviceFamily': [1],
                  'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True}}, f)
with (root / 'entitlements.plist').open('wb') as f:
    plistlib.dump({'application-identifier': 'IDENTITYCHECK.' + bundle,
                  'keychain-access-groups': ['IDENTITYCHECK.' + bundle]}, f)
PY
xcrun --sdk iphonesimulator swiftc -swift-version 6 -D DEBUG -parse-as-library \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target "$(uname -m)-apple-ios17.0-simulator" \
    UploadVideo/API.swift UploadVideo/DeviceIdentity.swift tools/DeviceKeychainCheck.swift \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker "$identity_tmp/entitlements.plist" \
    -o "$identity_tmp/IdentityCheck.app/IdentityCheck"
# Simulator entitlements live in __TEXT; signing iOS-only entitlements into the
# host code signature prevents macOS from launching the simulator executable.
codesign --force --sign - "$identity_tmp/IdentityCheck.app"
xcrun simctl install "$IDENTITY_CHECK_SIMULATOR" "$identity_tmp/IdentityCheck.app"
cat > "$identity_tmp/launch-check" <<'SH'
#!/bin/bash
set -euo pipefail
xcrun simctl launch --terminate-running-process --console "$IDENTITY_CHECK_SIMULATOR" "$IDENTITY_CHECK_BUNDLE" "$1" persist
xcrun simctl launch --terminate-running-process --console "$IDENTITY_CHECK_SIMULATOR" "$IDENTITY_CHECK_BUNDLE" "$1" verify
SH
chmod +x "$identity_tmp/launch-check"
cd server
IDENTITY_PROBE="$identity_tmp/launch-check" go test -race -count=1 -v -run '^TestSwiftDeviceRegistration$' ./...
