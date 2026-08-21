#!/bin/bash
# Fails the build if the Settings font choice stops covering the whole app.
# `appFontScope` (Sources/Dosa/Typography.swift) makes the chosen face the
# inherited default for a view subtree; every surface root is expected to set
# it, and no other view should reach for a raw `.font(` call that would
# silently opt back out of it. See the Typography section of
# docs/TECHNICAL_DESIGN.md for the full exception list (menus, alerts,
# popup/segmented pickers, SF Symbol sizing).
#
# Grep/awk-level checks on purpose, same rationale as check-window-chrome.sh:
# the failure mode is a specific call appearing at all, not a subtle misuse of
# it, so a pattern match is both sufficient and impossible to argue with.
set -uo pipefail
cd "$(dirname "$0")/.."

SOURCES=Sources/Dosa
FAILED=0

# --- Check 1: every surface root still scopes the chosen font ---------------
SCOPE_ROOTS=(
    "Sources/Dosa/Views/ContentView.swift"
    "Sources/Dosa/Views/SettingsView.swift"
    "Sources/Dosa/Views/SearchViews.swift"
    "Sources/Dosa/Views/TranscriptView.swift"
    "Sources/Dosa/Views/SharedViews.swift"
    "Sources/Dosa/Views/CalendarEventDetailView.swift"
    "Sources/Dosa/Views/QuickSettingsPanel.swift"
)
for f in "${SCOPE_ROOTS[@]}"; do
    if ! grep -q 'appFontScope(' "$f" 2>/dev/null; then
        echo "✗ $f no longer calls appFontScope() — its subtree will fall back to the" >&2
        echo "  system font instead of the user's Settings choice. See the Typography" >&2
        echo "  section of docs/TECHNICAL_DESIGN.md." >&2
        echo >&2
        FAILED=1
    fi
done

# --- Check 2: no raw .font( call outside the allowed exceptions -------------
# Allowed without comment: Typography.swift and DiffEngine.swift build the
# fonts; a `.font(` on a line whose own or immediately preceding line sizes an
# `Image(systemName:` (SF Symbols must stay on the system face to render).
# Anything else needs a trailing `// system-font: <reason>` marker so the
# exception is visible in review instead of hidden in this script.
# find | xargs rather than a bash array/mapfile: the macOS-shipped /bin/bash
# is 3.2 and has neither.
RAW_FONT_HITS=$(find "$SOURCES" -name '*.swift' \
        ! -name 'Typography.swift' ! -name 'DiffEngine.swift' -print0 \
    | xargs -0 awk '
    FNR == 1 { prev = "" }
    {
        line = $0
        trimmed = line
        sub(/^[[:space:]]*/, "", trimmed)
        is_comment_line = (trimmed ~ /^(\/\/|\/\*\*|\*)/)
        if (!is_comment_line && line ~ /\.font\(/) {
            has_marker = (line ~ /\/\/ system-font:/)
            symbol_here = (line ~ /Image\(systemName:/)
            symbol_prev = (prev ~ /Image\(systemName:/)
            if (!has_marker && !symbol_here && !symbol_prev) {
                print FILENAME ":" FNR ": " line
            }
        }
        prev = line
    }
' 2>/dev/null || true)

if [ -n "$RAW_FONT_HITS" ]; then
    echo "✗ Raw .font( call bypasses the Settings font choice:" >&2
    echo "$RAW_FONT_HITS" | sed 's/^/    /' >&2
    echo >&2
    echo "  Use .appFont(...) / .appMonoFont(...) / .appFontScope(...) instead, so the" >&2
    echo "  chosen face applies here too. If this really must stay on the system face" >&2
    echo "  (an SF Symbol size, or another documented exception), add a trailing" >&2
    echo "  '// system-font: <reason>' comment on the same line." >&2
    echo >&2
    FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
    echo "Typography check failed — see the Typography section of docs/TECHNICAL_DESIGN.md." >&2
    echo "The fix is to use the app's font helpers or add a scope, not to loosen this check." >&2
    exit 1
fi

echo "Typography coverage OK."
