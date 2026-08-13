#!/bin/bash
# Builds Dosa.app into build/Dosa.app
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Building Dosa (release)…"
swift build -c release

echo "==> Generating brand assets (app icon + in-app mark)…"
swift Scripts/make_icon.swift Resources

APP=build/Dosa.app
echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dosa "$APP/Contents/MacOS/Dosa"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/dosa-mark-light.png "$APP/Contents/Resources/dosa-mark-light.png"
cp Resources/dosa-mark-dark.png "$APP/Contents/Resources/dosa-mark-dark.png"

echo "==> Signing (ad-hoc)…"
codesign --force --sign - "$APP"

echo "==> Done. Launch with: open ${APP}"
