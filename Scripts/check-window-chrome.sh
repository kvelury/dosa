#!/bin/bash
# Fails the build if a UI change reintroduces one of the window-chrome hacks
# that have each shipped a broken window at least once — traffic lights
# disappearing, a sidebar toggle floating in the middle of the sidebar, a dead
# strip across the top. See §9b of docs/TECHNICAL_DESIGN.md.
#
# These are grep-level checks on purpose: the failure mode is always a specific
# API being called at all, not a subtle misuse of it, so a pattern match is both
# sufficient and impossible to argue with.
set -uo pipefail
cd "$(dirname "$0")/.."

SOURCES=Sources/Dosa
FAILED=0

# report <pattern> <explanation>  — flags any match outside comment lines.
report() {
    local pattern="$1" explanation="$2" hits
    hits=$(grep -rn --include='*.swift' -E "$pattern" "$SOURCES" \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|///|\*)' || true)
    if [ -n "$hits" ]; then
        echo "✗ $explanation" >&2
        echo "$hits" | sed 's/^/    /' >&2
        echo >&2
        FAILED=1
    fi
}

report '\.toolbar\([[:space:]]*\.hidden[[:space:]]*,[[:space:]]*for:[[:space:]]*\.windowToolbar' \
    "Hiding the window toolbar removes the sidebar toggle and collapses the titlebar,
  taking the traffic lights with it. Use .toolbarBackground(.hidden, for: .windowToolbar)
  to hide the material while keeping the toolbar."

report '\.toolbar\([[:space:]]*removing:' \
    "Removing a default toolbar item strips the only sidebar toggle (or the title slot
  the split view needs). Leave NavigationSplitView's toolbar alone."

report 'standardWindowButton' \
    "Traffic lights live in the window's titlebar view, a sibling of SwiftUI's content
  view — measuring them to place a SwiftUI view puts it in the wrong coordinate space.
  Do not position UI relative to the traffic lights."

report 'titlebarAppearsTransparent|titleVisibility|\.styleMask' \
    "Mutating NSWindow chrome from a view fights SwiftUI's window management and has
  killed the traffic lights before. Window styling belongs in .windowStyle(...) on the
  Scene in DosaApp.swift, and nowhere else."

report 'NavigationSplitView\([[:space:]]*columnVisibility:' \
    "Hand-driving column visibility exists only to power a hand-placed sidebar toggle.
  Let NavigationSplitView own its own visibility and its own toggle."

# .windowStyle belongs to the Scene; a stray one in a view means window styling
# has leaked back into the view layer.
STRAY_STYLE=$(grep -rln --include='*.swift' '\.windowStyle(' "$SOURCES" \
    | grep -v 'DosaApp.swift' || true)
if [ -n "$STRAY_STYLE" ]; then
    echo "✗ .windowStyle belongs on the Scene in DosaApp.swift only:" >&2
    echo "$STRAY_STYLE" | sed 's/^/    /' >&2
    echo >&2
    FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
    echo "Window-chrome check failed — see §9b of docs/TECHNICAL_DESIGN.md." >&2
    echo "The fix is to remove the offending call, not to loosen this check." >&2
    exit 1
fi

echo "Window chrome OK."
