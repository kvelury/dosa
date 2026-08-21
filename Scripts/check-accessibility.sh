#!/bin/bash
# Fails the build on the accessibility regressions this codebase has already
# fixed once: bare system muted-text colors that measure below WCAG AA,
# opacity applied straight to text, and icon-only controls with no name for
# VoiceOver. See docs/TECHNICAL_DESIGN.md's Accessibility section.
#
# Grep/awk-level checks on purpose, same rationale as check-window-chrome.sh
# and check-typography.sh: the failure mode is a specific pattern appearing at
# all, not a subtle misuse of it, so a pattern match is both sufficient and
# impossible to argue with. Check 3 (icon-only buttons) is a heuristic over a
# line window rather than real parsing — it can miss unusual formatting, but a
# false negative here is a missed regression, not a broken build, so it errs
# toward not blocking legitimate code.
set -uo pipefail
cd "$(dirname "$0")/.."

SOURCES=Sources/Dosa
FAILED=0

# --- Check 1: no bare .secondary/.tertiary on text -----------------------
# `.foregroundStyle(.secondary)` measures ~3.98:1 in light mode (below the
# 4.5:1 AA floor); `.tertiary` is worse. Theme.secondaryTextColor /
# Theme.tertiaryTextColor are the AA-checked replacements (see Theme.swift).
# Escape hatch: a trailing `// system-color: <reason>` comment, mirroring the
# `// system-font:` convention in check-typography.sh.
BARE_COLOR_HITS=$(grep -rn '\.foregroundStyle(\.secondary)\|\.foregroundStyle(\.tertiary)' "$SOURCES" \
    | grep -v '// system-color:' || true)

if [ -n "$BARE_COLOR_HITS" ]; then
    echo "✗ Bare .secondary/.tertiary used as text color (fails WCAG AA):" >&2
    echo "$BARE_COLOR_HITS" | sed 's/^/    /' >&2
    echo >&2
    echo "  Use Theme.secondaryTextColor / Theme.tertiaryTextColor instead. If this" >&2
    echo "  really isn't text (a border, a fill), add a trailing '// system-color: <reason>'." >&2
    echo >&2
    FAILED=1
fi

# --- Check 2: no .opacity( applied directly to a Text( literal -------------
# Escape hatch: a trailing `// contrast-ok: <reason>` comment — e.g. the
# recording-toast ellipsis, whose unlit dots deliberately dim (not vanish).
OPACITY_TEXT_HITS=$(grep -rn 'Text(.*\.opacity(' "$SOURCES" \
    | grep -v '// contrast-ok:' || true)

if [ -n "$OPACITY_TEXT_HITS" ]; then
    echo "✗ .opacity( applied directly to text — can silently drop below AA contrast:" >&2
    echo "$OPACITY_TEXT_HITS" | sed 's/^/    /' >&2
    echo >&2
    echo "  Use a Theme text token instead, or add '// contrast-ok: <reason>' if the" >&2
    echo "  opacity is deliberate and bounded (e.g. never goes below ~0.4)." >&2
    echo >&2
    FAILED=1
fi

# --- Check 3: icon-only Button/Menu labels need an accessible name ---------
# Heuristic: a `label:` closure whose only content is an `Image(systemName:`
# (no `Text(`/`Label(` alongside it) needs an `.accessibilityLabel(`,
# `.accessibilityHidden(`, or `.help(` + `.accessibilityLabel(` within the
# surrounding ~15 lines. Escape hatch: `// a11y-ok: <reason>`.
ICON_ONLY_HITS=$(awk '
    { lines[NR] = $0 }
    END {
        for (i = 1; i <= NR; i++) {
            if (lines[i] !~ /label: *\{ *$/) continue
            imageLine = 0
            hasTextOrLabel = 0
            depth = 1
            j = i + 1
            while (j <= NR && depth > 0 && j <= i + 20) {
                line = lines[j]
                n = gsub(/\{/, "{", line); depth += n
                n = gsub(/\}/, "}", line); depth -= n
                if (lines[j] ~ /Image\(systemName:/) imageLine = j
                if (lines[j] ~ /Text\(|Label\(/) hasTextOrLabel = 1
                j++
            }
            if (imageLine == 0 || hasTextOrLabel) continue
            window_start = (i - 15 > 1) ? i - 15 : 1
            window_end = (j + 15 < NR) ? j + 15 : NR
            hasA11y = 0
            for (k = window_start; k <= window_end; k++) {
                if (lines[k] ~ /accessibilityLabel\(|accessibilityHidden\(|\/\/ a11y-ok:/) hasA11y = 1
            }
            if (!hasA11y) print FILENAME ":" imageLine ": " lines[imageLine]
        }
    }
' $(find "$SOURCES" -name '*.swift') 2>/dev/null || true)

if [ -n "$ICON_ONLY_HITS" ]; then
    echo "✗ Icon-only button/menu label with no accessible name nearby:" >&2
    echo "$ICON_ONLY_HITS" | sed 's/^/    /' >&2
    echo >&2
    echo "  Add .accessibilityLabel(\"...\") (or wrap in Label(\"...\", systemImage:)" >&2
    echo "  with .labelStyle(.iconOnly), which gets one for free). If it's genuinely" >&2
    echo "  decorative, .accessibilityHidden(true) instead. False positive from this" >&2
    echo "  script's line-window heuristic? Add '// a11y-ok: <reason>' nearby." >&2
    echo >&2
    FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
    echo "Accessibility check failed — see the Accessibility section of docs/TECHNICAL_DESIGN.md." >&2
    echo "The fix is to use the app's contrast/labeling helpers, not to loosen this check." >&2
    exit 1
fi

echo "Accessibility coverage OK."
