import Foundation
import AppKit
import SwiftUI

/// A curated, readability-safe palette. Every token carries its own light/dark
/// variants via dynamic NSColor providers, so appearance flips resolve correctly.
struct ThemePalette {
    let name: String
    let accent: NSColor
    let highlight: NSColor
    let highlightDeep: NSColor
    let editorBackground: NSColor
    let cardFill: NSColor
    let codeSpan: NSColor
    let defaultDosaColorName: String

    var accentColor: Color { Color(nsColor: accent) }
    var highlightColor: Color { Color(nsColor: highlight) }
    var highlightDeepColor: Color { Color(nsColor: highlightDeep) }
    var editorBackgroundColor: Color { Color(nsColor: editorBackground) }
    var cardFillColor: Color { Color(nsColor: cardFill) }

    // MARK: - WCAG AA text tokens
    //
    // Computed, not hand-picked: each resolves `accent`/status colors against
    // `cardFill` at the moment it's drawn (via `Theme.derived`), so a custom
    // accent override, a new preset, or a future palette tweak can never
    // silently reintroduce a contrast failure the way a hardcoded hex could.
    // `ContrastSelfChecks` asserts every one of these clears AA across every
    // preset × accent-override × appearance combination.

    /// `accent`, darkened/lightened only as far as needed to read as AA text
    /// (≥4.5:1, ≥7:1 under Increase Contrast) on `cardFill`. For accent-colored
    /// *text* — chips, drop hints, badges. Fills still use the plain `accentColor`.
    var accentText: NSColor {
        Theme.derived { [accent, cardFill] in accent.ensuringContrast(Theme.aaTextRatio, against: cardFill) }
    }
    var accentTextColor: Color { Color(nsColor: accentText) }

    /// White or black, whichever reads on a circle/capsule filled with `accent`.
    var onAccent: NSColor {
        Theme.derived { [accent] in
            accent.wcagRelativeLuminance <= Theme.onAccentLuminanceThreshold ? .white : .black
        }
    }
    var onAccentColor: Color { Color(nsColor: onAccent) }

    /// Hover lift for interactive chrome. Accent-tinted rather than neutral so the cue
    /// reads as part of the theme. `FloatingChrome`'s black shadow is a different job:
    /// that one models a panel floating over content, this one models a target lifting
    /// under the pointer. Do not unify them.
    var hoverShadowColor: Color { accentColor.opacity(0.28) }

    /// Status colors, contrast-adjusted against `cardFill` the same way as `accentText`.
    var dangerText: NSColor {
        Theme.derived { [cardFill] in NSColor.systemRed.ensuringContrast(Theme.aaTextRatio, against: cardFill) }
    }
    var warningText: NSColor {
        Theme.derived { [cardFill] in NSColor.systemOrange.ensuringContrast(Theme.aaTextRatio, against: cardFill) }
    }
    var successText: NSColor {
        Theme.derived { [cardFill] in NSColor.systemGreen.ensuringContrast(Theme.aaTextRatio, against: cardFill) }
    }
    var dangerTextColor: Color { Color(nsColor: dangerText) }
    var warningTextColor: Color { Color(nsColor: warningText) }
    var successTextColor: Color { Color(nsColor: successText) }
}

enum Theme {
    static let presetNames = ["Classic", "Crepe", "Masala", "Chutney", "Slate"]
    static let accentOverrideOptions = ["Theme Default", "Blue", "Purple", "Pink", "Green", "Graphite"]

    /// The active palette: the selected preset with the accent override applied.
    static var current: ThemePalette {
        var palette = palette(named: AppSettings.currentThemeName)
        let override = AppSettings.currentAccentOverride
        if override != "Theme Default", let accent = accentOverrideColor(named: override) {
            palette = ThemePalette(
                name: palette.name,
                accent: accent,
                highlight: palette.highlight,
                highlightDeep: palette.highlightDeep,
                editorBackground: palette.editorBackground,
                cardFill: palette.cardFill,
                codeSpan: palette.codeSpan,
                defaultDosaColorName: palette.defaultDosaColorName
            )
        }
        return palette
    }

    /// Changes whenever any styling-relevant setting changes; open editors
    /// compare against it to know when to re-style. Includes font and text size
    /// so a change restyles markdown without a Settings-close rebuild.
    static var styleFingerprint: String {
        "\(AppSettings.currentThemeName)|\(AppSettings.currentAccentOverride)|\(AppSettings.currentDosaColorName)|\(AppSettings.currentFontChoice.rawValue)|\(AppSettings.currentTextSize.rawValue)"
    }

    static func accentOverrideColor(named name: String) -> NSColor? {
        switch name {
        case "Blue": return .systemBlue
        case "Purple": return .systemPurple
        case "Pink": return .systemPink
        case "Green": return .systemGreen
        case "Graphite": return dynamic(light: rgb(0.35, 0.38, 0.42), dark: rgb(0.68, 0.72, 0.78))
        default: return nil
        }
    }

    static func palette(named name: String) -> ThemePalette {
        switch name {
        case "Crepe":
            // Coffee-and-cream: espresso accent, caramel highlight, distinctly
            // cream background — kept well away from Masala's red-orange spice hues.
            return ThemePalette(
                name: "Crepe",
                accent: dynamic(light: rgb(0.36, 0.25, 0.18), dark: rgb(0.78, 0.62, 0.48)),
                // Light-mode highlight darkened from (0.66,0.47,0.12) — the
                // original measured 3.29:1 on cardFill, below the 4.5:1 AA floor.
                highlight: dynamic(light: rgb(0.540, 0.384, 0.098), dark: rgb(0.92, 0.75, 0.40)),
                highlightDeep: dynamic(light: rgb(0.44, 0.29, 0.10), dark: rgb(0.74, 0.57, 0.30)),
                editorBackground: dynamic(light: rgb(0.985, 0.960, 0.905), dark: rgb(0.125, 0.113, 0.095)),
                cardFill: dynamic(light: rgb(0.955, 0.920, 0.845), dark: rgb(0.185, 0.165, 0.135)),
                codeSpan: dynamic(light: rgb(0.48, 0.36, 0.08), dark: rgb(0.88, 0.72, 0.38)),
                defaultDosaColorName: "Dark Green"
            )
        case "Masala":
            return ThemePalette(
                name: "Masala",
                accent: dynamic(light: rgb(0.72, 0.26, 0.14), dark: rgb(0.95, 0.55, 0.40)),
                // Light-mode highlight darkened from (0.85,0.55,0.10) — measured
                // 2.31:1 on cardFill, the worst failure in the palette.
                highlight: dynamic(light: rgb(0.576, 0.373, 0.068), dark: rgb(0.98, 0.72, 0.30)),
                // Dark-mode highlightDeep lightened from (0.85,0.40,0.35) — measured
                // 4.11:1 on cardFill, just under the 4.5:1 AA floor.
                highlightDeep: dynamic(light: rgb(0.55, 0.10, 0.08), dark: rgb(0.863, 0.452, 0.406)),
                editorBackground: dynamic(light: rgb(0.975, 0.965, 0.955), dark: rgb(0.115, 0.105, 0.100)),
                cardFill: dynamic(light: rgb(0.945, 0.925, 0.905), dark: rgb(0.180, 0.160, 0.150)),
                codeSpan: dynamic(light: rgb(0.62, 0.20, 0.35), dark: rgb(0.95, 0.55, 0.65)),
                defaultDosaColorName: "Dark Blue"
            )
        case "Chutney":
            return ThemePalette(
                name: "Chutney",
                // Light-mode accent darkened slightly from (0.13,0.50,0.27) —
                // measured 4.32:1 on cardFill, just under the 4.5:1 AA floor.
                accent: dynamic(light: rgb(0.125, 0.481, 0.260), dark: rgb(0.45, 0.82, 0.55)),
                // Light-mode highlight darkened from (0.42,0.58,0.10) — measured
                // 3.10:1 on cardFill, below the 4.5:1 AA floor.
                highlight: dynamic(light: rgb(0.333, 0.460, 0.079), dark: rgb(0.72, 0.88, 0.35)),
                highlightDeep: dynamic(light: rgb(0.10, 0.40, 0.20), dark: rgb(0.45, 0.70, 0.45)),
                editorBackground: dynamic(light: rgb(0.955, 0.975, 0.960), dark: rgb(0.100, 0.120, 0.105)),
                cardFill: dynamic(light: rgb(0.910, 0.945, 0.915), dark: rgb(0.150, 0.185, 0.160)),
                // Light-mode codeSpan darkened from (0.05,0.50,0.45) — measured
                // 4.21:1 on cardFill, just under the 4.5:1 AA floor.
                codeSpan: dynamic(light: rgb(0.047, 0.473, 0.426), dark: rgb(0.40, 0.85, 0.78)),
                defaultDosaColorName: "Purple"
            )
        case "Slate":
            return ThemePalette(
                name: "Slate",
                accent: dynamic(light: rgb(0.35, 0.38, 0.42), dark: rgb(0.68, 0.72, 0.78)),
                highlight: dynamic(light: rgb(0.30, 0.42, 0.58), dark: rgb(0.58, 0.70, 0.85)),
                // Dark-mode highlightDeep lightened from (0.45,0.55,0.70) —
                // measured 4.12:1 on cardFill, just under the 4.5:1 AA floor.
                highlightDeep: dynamic(light: rgb(0.20, 0.28, 0.40), dark: rgb(0.491, 0.584, 0.722)),
                editorBackground: dynamic(light: rgb(0.965, 0.970, 0.975), dark: rgb(0.105, 0.110, 0.120)),
                cardFill: dynamic(light: rgb(0.925, 0.930, 0.940), dark: rgb(0.165, 0.170, 0.185)),
                codeSpan: dynamic(light: rgb(0.42, 0.36, 0.55), dark: rgb(0.72, 0.68, 0.88)),
                defaultDosaColorName: "Grey"
            )
        default:
            return ThemePalette(
                name: "Classic",
                accent: .systemBlue,
                highlight: .systemOrange,
                highlightDeep: .systemRed,
                editorBackground: .textBackgroundColor,
                cardFill: dynamic(light: rgb(0.945, 0.945, 0.950), dark: rgb(0.165, 0.165, 0.175)),
                codeSpan: .systemPink,
                defaultDosaColorName: "Grey"
            )
        }
    }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    // MARK: - Accessibility: AA-floor muted text + contrast infrastructure

    /// 4.5:1 (WCAG AA for normal text), raised to 7:1 (AAA) when the user has
    /// System Settings ▸ Accessibility ▸ Display ▸ Increase Contrast on.
    static var aaTextRatio: CGFloat {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 7.0 : 4.5
    }

    /// Below this relative luminance, white reads better than black on a fill
    /// of that luminance — the exact crossover where both contrast equally
    /// (`sqrt(0.05 × 1.05) − 0.05`).
    static let onAccentLuminanceThreshold: CGFloat = (0.05 * 1.05).squareRoot() - 0.05

    /// Replacement for `.secondary` on text. macOS's `secondaryLabelColor`
    /// measures 3.98:1 in light mode against a white background — below the
    /// 4.5:1 AA floor — and worse still against every theme's `cardFill`. These
    /// fixed values were solved against the tightest background in each mode
    /// across all five presets (Crepe `cardFill` light, Chutney `cardFill`
    /// dark), so they clear AA everywhere without per-theme variation.
    static let secondaryText: NSColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        switch (dark, highContrast) {
        case (false, false): return rgb(0.366, 0.366, 0.366)
        case (false, true): return rgb(0.271, 0.271, 0.271)
        case (true, false): return rgb(0.642, 0.642, 0.642)
        case (true, true): return rgb(0.773, 0.773, 0.773)
        }
    }
    static var secondaryTextColor: Color { Color(nsColor: secondaryText) }

    /// Replacement for `.tertiary` on text. macOS's `tertiaryLabelColor`
    /// measures ~1.9:1 in light mode — nowhere close to AA. Solved the same
    /// way as `secondaryText`, one step lighter/darker.
    static let tertiaryText: NSColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        switch (dark, highContrast) {
        case (false, false): return rgb(0.418, 0.418, 0.418)
        case (false, true): return rgb(0.306, 0.306, 0.306)
        case (true, false): return rgb(0.578, 0.578, 0.578)
        case (true, true): return rgb(0.724, 0.724, 0.724)
        }
    }
    static var tertiaryTextColor: Color { Color(nsColor: tertiaryText) }

    /// Wraps `resolve` — which may itself read other dynamic NSColors, e.g. a
    /// palette's `accent` — as a new dynamic NSColor. Composing dynamic colors
    /// this way, rather than reading their components eagerly, is what keeps a
    /// derived token (like `accentText`) correct no matter when or under which
    /// appearance it's first evaluated: `resolve` runs with that appearance
    /// temporarily current, so any dynamic color it reads resolves to the
    /// matching light/dark variant instead of whatever was active at call time.
    static func derived(_ resolve: @escaping () -> NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var result = NSColor.black
            appearance.performAsCurrentDrawingAppearance {
                result = resolve()
            }
            return result
        }
    }
}

extension NSColor {
    /// Relative luminance per WCAG 2.x, computed in sRGB.
    var wcagRelativeLuminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0 }
        func channel(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent) + 0.0722 * channel(c.blueComponent)
    }

    /// WCAG contrast ratio against another color; always ≥ 1.
    func wcagContrastRatio(against other: NSColor) -> CGFloat {
        let l1 = wcagRelativeLuminance, l2 = other.wcagRelativeLuminance
        let hi = max(l1, l2), lo = min(l1, l2)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Darkens (against a light background) or lightens (against a dark one)
    /// this color's RGB toward black/white, preserving hue, until it clears
    /// `ratio` against `background`. Returns `self` unchanged if it already
    /// clears the ratio. Used to keep decorative theme colors legible as text
    /// without hand-tuning every preset × accent-override × appearance
    /// combination by hand.
    func ensuringContrast(_ ratio: CGFloat, against background: NSColor) -> NSColor {
        guard let c = usingColorSpace(.sRGB), let bg = background.usingColorSpace(.sRGB) else { return self }
        if c.wcagContrastRatio(against: bg) >= ratio { return self }
        let darken = bg.wcagRelativeLuminance > 0.4

        func mixed(_ t: CGFloat) -> NSColor {
            if darken {
                return NSColor(red: c.redComponent * t, green: c.greenComponent * t,
                                blue: c.blueComponent * t, alpha: c.alphaComponent)
            } else {
                return NSColor(red: c.redComponent + (1 - c.redComponent) * t,
                                green: c.greenComponent + (1 - c.greenComponent) * t,
                                blue: c.blueComponent + (1 - c.blueComponent) * t,
                                alpha: c.alphaComponent)
            }
        }

        // Binary search for the mix fraction closest to the original color
        // (largest `t` when darkening, smallest when lightening) that still
        // clears `ratio`. Contrast moves monotonically with `t` in each case,
        // so a fixed 30-iteration bisection converges well past float precision.
        var lo: CGFloat = 0, hi: CGFloat = 1
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            let feasible = mixed(mid).wcagContrastRatio(against: bg) >= ratio
            if darken {
                if feasible { lo = mid } else { hi = mid }
            } else {
                if feasible { hi = mid } else { lo = mid }
            }
        }
        return mixed(darken ? lo : hi)
    }
}
