#!/bin/bash
# Builds Dosa.app into build/Dosa.app
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building Dosa (release)…"
swift build -c release

if [ ! -f Resources/AppIcon.icns ]; then
    echo "==> Generating app icon…"
    swift Scripts/make_icon.swift Resources || echo "    (icon generation skipped)"
fi

APP=build/Dosa.app
echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dosa "$APP/Contents/MacOS/Dosa"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "==> Done. Launch with: open ${APP}"
