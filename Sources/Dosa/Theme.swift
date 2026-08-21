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
    /// compare against it to know when to re-style. Includes font so a typeface
    /// change restyles markdown without a Settings-close rebuild.
    static var styleFingerprint: String {
        "\(AppSettings.currentThemeName)|\(AppSettings.currentAccentOverride)|\(AppSettings.currentDosaColorName)|\(AppSettings.currentFontChoice.rawValue)"
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
                highlight: dynamic(light: rgb(0.66, 0.47, 0.12), dark: rgb(0.92, 0.75, 0.40)),
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
                highlight: dynamic(light: rgb(0.85, 0.55, 0.10), dark: rgb(0.98, 0.72, 0.30)),
                highlightDeep: dynamic(light: rgb(0.55, 0.10, 0.08), dark: rgb(0.85, 0.40, 0.35)),
                editorBackground: dynamic(light: rgb(0.975, 0.965, 0.955), dark: rgb(0.115, 0.105, 0.100)),
                cardFill: dynamic(light: rgb(0.945, 0.925, 0.905), dark: rgb(0.180, 0.160, 0.150)),
                codeSpan: dynamic(light: rgb(0.62, 0.20, 0.35), dark: rgb(0.95, 0.55, 0.65)),
                defaultDosaColorName: "Dark Blue"
            )
        case "Chutney":
            return ThemePalette(
                name: "Chutney",
                accent: dynamic(light: rgb(0.13, 0.50, 0.27), dark: rgb(0.45, 0.82, 0.55)),
                highlight: dynamic(light: rgb(0.42, 0.58, 0.10), dark: rgb(0.72, 0.88, 0.35)),
                highlightDeep: dynamic(light: rgb(0.10, 0.40, 0.20), dark: rgb(0.45, 0.70, 0.45)),
                editorBackground: dynamic(light: rgb(0.955, 0.975, 0.960), dark: rgb(0.100, 0.120, 0.105)),
                cardFill: dynamic(light: rgb(0.910, 0.945, 0.915), dark: rgb(0.150, 0.185, 0.160)),
                codeSpan: dynamic(light: rgb(0.05, 0.50, 0.45), dark: rgb(0.40, 0.85, 0.78)),
                defaultDosaColorName: "Purple"
            )
        case "Slate":
            return ThemePalette(
                name: "Slate",
                accent: dynamic(light: rgb(0.35, 0.38, 0.42), dark: rgb(0.68, 0.72, 0.78)),
                highlight: dynamic(light: rgb(0.30, 0.42, 0.58), dark: rgb(0.58, 0.70, 0.85)),
                highlightDeep: dynamic(light: rgb(0.20, 0.28, 0.40), dark: rgb(0.45, 0.55, 0.70)),
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
}
