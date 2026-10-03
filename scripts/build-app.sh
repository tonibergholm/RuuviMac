#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_OPTIONS=()
# Swift 6.4 defaults to swiftbuild, whose automatic test/resource signing can
# reject Finder metadata in synced Documents folders. Keep older Swift compatible.
if swift build --help | /usr/bin/grep -q 'native.*Native Build System'; then
    BUILD_OPTIONS=(--build-system native)
fi
swift build "${BUILD_OPTIONS[@]}" -c release
BIN_DIR=$(swift build "${BUILD_OPTIONS[@]}" -c release --show-bin-path)
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/RuuviMac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RuuviMac" "$APP/Contents/MacOS/RuuviMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/BTKit-LICENSE.txt LICENSE "$APP/Contents/Resources/"
xattr -cr "$APP"
codesign --force --sign - --entitlements Resources/RuuviMac.entitlements "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p dist
rm -rf "$PWD/dist/RuuviMac.app"
ditto "$APP" "$PWD/dist/RuuviMac.app"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$PWD/dist/RuuviMac-macOS.zip"
echo "Built $PWD/dist/RuuviMac.app and $PWD/dist/RuuviMac-macOS.zip"
