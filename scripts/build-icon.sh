#!/bin/bash
# Apple compiles the layered icon and its legacy fallback on Xcode 26+.
# Older toolchains use the checked-in, Apple-generated ICNS.
set -euo pipefail
cd "$(dirname "$0")/.."
DESTINATION="${1:?Pass the app Resources destination}"
mkdir -p "$DESTINATION"
XCODE_MAJOR=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
if [[ "${XCODE_MAJOR:-0}" -ge 26 ]]; then
    ICON_STAGING=$(mktemp -d)
    trap 'rm -rf "$ICON_STAGING"' EXIT
    xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$ICON_STAGING" \
        --output-format human-readable-text --platform macosx \
        --minimum-deployment-target 13.0 --app-icon AppIcon \
        --output-partial-info-plist "$ICON_STAGING/icon-info.plist"
    cp "$ICON_STAGING/Assets.car" "$ICON_STAGING/AppIcon.icns" "$DESTINATION/"
else
    cp Resources/AppIcon.icns "$DESTINATION/"
fi
