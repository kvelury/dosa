#!/bin/bash
# Builds Dosa.app into build/Dosa.app.
#   --install   also replace /Applications/Dosa.app with the fresh build
# Installing is opt-in on purpose: during development this script runs
# constantly, and silently replacing the copy in /Applications on every build
# makes it ambiguous which Dosa you're running — and macOS re-prompts for
# permissions when the bundle it granted them to keeps changing underneath it.
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=false
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        -h|--help)
            echo "Usage: ./build.sh [--install]"
            echo "  --install   copy the built app over /Applications/Dosa.app"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg (try --help)" >&2
            exit 1
            ;;
    esac
done

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

if [ "$INSTALL" = true ]; then
    DEST="/Applications/Dosa.app"
    if [ ! -w /Applications ]; then
        echo "==> Cannot write to /Applications — re-run with sudo, or copy manually:" >&2
        echo "    sudo cp -R \"$PWD/$APP\" /Applications/" >&2
        exit 1
    fi
    # Replacing the bundle out from under a running copy leaves it in a broken
    # half-state, so stop it first. Ignored if Dosa isn't running.
    osascript -e 'quit app "Dosa"' >/dev/null 2>&1 || true
    echo "==> Installing to ${DEST}…"
    # Delete rather than copy over the top, so files dropped in a later
    # version can't linger inside the installed bundle.
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "==> Done. Installed to ${DEST} — launch it from Applications or Spotlight."
else
    echo "==> Done. Launch with: open ${APP}"
    echo "    (./build.sh --install also replaces /Applications/Dosa.app)"
fi
