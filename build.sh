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

echo "==> Checking window chrome…"
./Scripts/check-window-chrome.sh

echo "==> Building Dosa (release)…"
swift build -c release

# Snapshot git identity before regenerating brand assets. Those files used to
# be written into tracked Resources/, which made every CI release look dirty
# and trip the guard below.
BUILD_CHANNEL=dev
[ "${DOSA_RELEASE_BUILD:-0}" = "1" ] && BUILD_CHANNEL=release

COMMIT=""; COMMIT_DATE=""; DIRTY=false
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    COMMIT=$(git rev-parse HEAD 2>/dev/null || true)
    COMMIT_DATE=$(git show -s --format=%cI HEAD 2>/dev/null || true)
    [ -n "$(git status --porcelain)" ] && DIRTY=true
fi
# Escape hatch: claim this build came from an older commit, so the updater can be
# exercised end to end without waiting on CI. See "Verify" below.
COMMIT="${DOSA_BUILD_COMMIT:-$COMMIT}"
[ -z "$COMMIT_DATE" ] && COMMIT_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# A release artifact that cannot be traced to a commit is worse than a failed
# build — this is the only place that invariant can be enforced.
if [ "$BUILD_CHANNEL" = release ]; then
    [ -n "$COMMIT" ] || { echo "==> DOSA_RELEASE_BUILD=1 but no git commit — refusing." >&2; exit 1; }
    [ "$DIRTY" = false ] || { echo "==> DOSA_RELEASE_BUILD=1 with uncommitted changes — refusing." >&2; git status --short >&2; exit 1; }
fi

echo "==> Generating brand assets (app icon + in-app mark)…"
BRAND_DIR=build/branding
rm -rf "$BRAND_DIR"
mkdir -p "$BRAND_DIR"
swift Scripts/make_icon.swift "$BRAND_DIR"

APP=build/Dosa.app
echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Dosa "$APP/Contents/MacOS/Dosa"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BRAND_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BRAND_DIR/dosa-mark-light.png" "$APP/Contents/Resources/dosa-mark-light.png"
cp "$BRAND_DIR/dosa-mark-dark.png" "$APP/Contents/Resources/dosa-mark-dark.png"

PLIST="$APP/Contents/Info.plist"

# Stamp the *copy* inside the bundle, never Resources/Info.plist: that one is
# tracked, and dirtying it on every build would trip the release guard.
# This must run BEFORE codesign — PlistBuddy after signing breaks the seal, and
# UpdateManager verifies the signature of what it downloads.
plist_set() {   # key type value
    /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Set :$1 $3" "$PLIST"
}

echo "==> Stamping build (${BUILD_CHANNEL}, ${COMMIT:-no-git})…"
plist_set DosaBuildCommit  string "$COMMIT"
plist_set DosaBuildDate    string "$COMMIT_DATE"
plist_set DosaBuildChannel string "$BUILD_CHANNEL"
plist_set DosaBuildDirty   bool   "$DIRTY"

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
