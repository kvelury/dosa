import AppKit

/// In-process WCAG contrast checks for the theme system. Invoked by
/// `DosaCalendarChecks` because this repo has no XCTest — see
/// `TypographySelfChecks` for the sibling pattern.
///
/// Walks every preset × accent-override × appearance combination (5 × 6 × 2 =
/// 60) and asserts each derived AA text token still clears its floor. This is
/// what makes a future palette edit provably safe instead of eyeballed: a
/// color that regresses contrast fails the build the same way a broken font
/// coverage change does.
///
/// Checks only against `cardFill`, not `editorBackground`, deliberately:
/// across every preset, `editorBackground` is lighter than `cardFill` in light
/// mode and darker in dark mode — i.e. always the *easier* background for
/// whichever text tint (dark-on-light or light-on-dark) is in play. `cardFill`
/// is therefore always the tighter case, so clearing it there clears both.
public enum ContrastSelfChecks {
    public static func run() -> Int {
        var failures = 0
        func expect(_ condition: Bool, _ message: String, line: Int = #line) {
            if !condition {
                failures += 1
                fputs("FAIL ContrastSelfChecks.swift:\(line): \(message)\n", stderr)
            }
        }

        guard let aqua = NSAppearance(named: .aqua), let darkAqua = NSAppearance(named: .darkAqua) else {
            expect(false, "could not construct system light/dark appearances to test against")
            return failures
        }
        let appearances: [(String, NSAppearance)] = [("light", aqua), ("dark", darkAqua)]

        let defaults = UserDefaults.standard
        let savedTheme = defaults.string(forKey: AppSettings.themeKey)
        let savedAccent = defaults.string(forKey: AppSettings.accentOverrideKey)
        defer {
            if let savedTheme { defaults.set(savedTheme, forKey: AppSettings.themeKey) }
            else { defaults.removeObject(forKey: AppSettings.themeKey) }
            if let savedAccent { defaults.set(savedAccent, forKey: AppSettings.accentOverrideKey) }
            else { defaults.removeObject(forKey: AppSettings.accentOverrideKey) }
        }

        for themeName in Theme.presetNames {
            for accentOverride in Theme.accentOverrideOptions {
                defaults.set(themeName, forKey: AppSettings.themeKey)
                defaults.set(accentOverride, forKey: AppSettings.accentOverrideKey)
                let palette = Theme.current

                for (modeName, appearance) in appearances {
                    appearance.performAsCurrentDrawingAppearance {
                        let context = "\(themeName) / \(accentOverride) / \(modeName)"
                        let cardFill = palette.cardFill

                        for (name, token) in [
                            ("accentText", palette.accentText),
                            ("dangerText", palette.dangerText),
                            ("warningText", palette.warningText),
                            ("successText", palette.successText),
                        ] {
                            let ratio = token.wcagContrastRatio(against: cardFill)
                            expect(
                                ratio >= 4.49,
                                "\(context): \(name) vs cardFill should clear 4.5:1 AA, measured \(String(format: "%.2f", ratio)):1"
                            )
                        }

                        // onAccent is a glyph on a filled circle/capsule — non-text,
                        // so WCAG's 3:1 (not 4.5:1) is the applicable floor.
                        let onAccentRatio = palette.onAccent.wcagContrastRatio(against: palette.accent)
                        expect(
                            onAccentRatio >= 2.99,
                            "\(context): onAccent vs accent should clear 3:1 (non-text), measured \(String(format: "%.2f", onAccentRatio)):1"
                        )
                    }
                }
            }
        }

        // secondaryText / tertiaryText are fixed (not per-theme) tokens, solved
        // against the tightest cardFill across all presets — verify that holds
        // for every preset individually, not just the one it was solved from.
        for themeName in Theme.presetNames {
            defaults.set(themeName, forKey: AppSettings.themeKey)
            defaults.set("Theme Default", forKey: AppSettings.accentOverrideKey)
            let palette = Theme.current

            for (modeName, appearance) in appearances {
                appearance.performAsCurrentDrawingAppearance {
                    let cardFill = palette.cardFill
                    for (name, token) in [("secondaryText", Theme.secondaryText), ("tertiaryText", Theme.tertiaryText)] {
                        let ratio = token.wcagContrastRatio(against: cardFill)
                        expect(
                            ratio >= 4.49,
                            "\(themeName) / \(modeName): \(name) vs cardFill should clear 4.5:1 AA, measured \(String(format: "%.2f", ratio)):1"
                        )
                    }
                }
            }
        }

        return failures
    }
}
