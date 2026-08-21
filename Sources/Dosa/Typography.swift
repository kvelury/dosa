import AppKit
import SwiftUI

/// Curated macOS-installed faces for the app-wide font setting.
/// System / Rounded / New York use Apple's optical system designs; the rest are
/// families Apple ships with macOS 14+.
enum AppFontChoice: String, CaseIterable, Identifiable {
    case system
    case systemRounded
    case newYork
    case avenirNext
    case helveticaNeue
    case charter
    case baskerville
    case gillSans
    case optima
    case palatino

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .systemRounded: return "System Rounded"
        case .newYork: return "New York"
        case .avenirNext: return "Avenir Next"
        case .helveticaNeue: return "Helvetica Neue"
        case .charter: return "Charter"
        case .baskerville: return "Baskerville"
        case .gillSans: return "Gill Sans"
        case .optima: return "Optima"
        case .palatino: return "Palatino"
        }
    }

    /// Named family for Font Book faces. Nil for SF Pro / Rounded / New York.
    var familyName: String? {
        switch self {
        case .system, .systemRounded, .newYork: return nil
        case .avenirNext: return "Avenir Next"
        case .helveticaNeue: return "Helvetica Neue"
        case .charter: return "Charter"
        case .baskerville: return "Baskerville"
        case .gillSans: return "Gill Sans"
        case .optima: return "Optima"
        case .palatino: return "Palatino"
        }
    }

    var systemDesign: NSFontDescriptor.SystemDesign? {
        switch self {
        case .system: return .default
        case .systemRounded: return .rounded
        case .newYork: return .serif
        default: return nil
        }
    }

    static func resolved(_ stored: String) -> AppFontChoice {
        AppFontChoice(rawValue: stored) ?? .system
    }
}

/// Semantic sizes/weights plus SwiftUI/AppKit resolution for the selected face.
enum Typography {
    enum Role {
        case hero
        case noteTitle
        case title2
        case title3
        case headline
        case body
        case callout
        case subheadline
        case caption
        case caption2

        var size: CGFloat {
            switch self {
            case .hero: return 36
            case .noteTitle: return 26
            case .title2: return 17
            case .title3: return 15
            case .headline, .body: return 13
            case .callout: return 12
            case .subheadline: return 11
            case .caption, .caption2: return 10
            }
        }

        var weight: Font.Weight {
            switch self {
            case .hero, .noteTitle: return .bold
            case .headline: return .semibold
            default: return .regular
            }
        }

        var nsWeight: NSFont.Weight { Typography.nsWeight(weight) }
    }

    static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    static func font(
        _ role: Role,
        weight: Font.Weight? = nil,
        choice: AppFontChoice = AppSettings.currentFontChoice
    ) -> Font {
        font(size: role.size, weight: weight ?? role.weight, choice: choice)
    }

    static func font(
        size: CGFloat,
        weight: Font.Weight = .regular,
        choice: AppFontChoice = AppSettings.currentFontChoice
    ) -> Font {
        Font(nsFont(size: size, weight: nsWeight(weight), choice: choice) as CTFont)
    }

    static func mono(_ role: Role, weight: Font.Weight? = nil) -> Font {
        mono(size: role.size, weight: weight ?? role.weight)
    }

    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(nsMono(size: size, weight: nsWeight(weight)) as CTFont)
    }

    static func nsFont(
        _ role: Role,
        weight: NSFont.Weight? = nil,
        choice: AppFontChoice = AppSettings.currentFontChoice
    ) -> NSFont {
        nsFont(size: role.size, weight: weight ?? role.nsWeight, choice: choice)
    }

    static func nsFont(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        choice: AppFontChoice = AppSettings.currentFontChoice
    ) -> NSFont {
        resolvedNSFont(size: size, weight: weight, choice: choice)
    }

    static func nsMono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Resolves a face, falling back to the system font if the family is missing
    /// or disabled on this Mac.
    static func resolvedNSFont(
        size: CGFloat,
        weight: NSFont.Weight,
        choice: AppFontChoice
    ) -> NSFont {
        resolvedNSFont(
            size: size,
            weight: weight,
            familyName: choice.familyName,
            design: choice.systemDesign
        )
    }

    static func resolvedNSFont(
        size: CGFloat,
        weight: NSFont.Weight,
        familyName: String?,
        design: NSFontDescriptor.SystemDesign?
    ) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: weight)
        if let design, design != .default {
            if let descriptor = fallback.fontDescriptor.withDesign(design),
               let font = NSFont(descriptor: descriptor, size: size) {
                return font
            }
            return fallback
        }
        guard let familyName else { return fallback }
        guard NSFontManager.shared.availableFontFamilies.contains(familyName) else {
            return fallback
        }
        // Building from a system-font descriptor and calling `withFamily`
        // leaves `.AppleSystemUIFont` in place. Start from a family descriptor.
        let namedDescriptor = NSFontDescriptor(fontAttributes: [
            .family: familyName,
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        if let font = NSFont(descriptor: namedDescriptor, size: size),
           matchesFamily(font, familyName) {
            return font
        }
        if let font = NSFontManager.shared.font(
            withFamily: familyName,
            traits: weight >= .semibold ? .boldFontMask : [],
            weight: fontManagerWeight(weight),
            size: size
        ), matchesFamily(font, familyName) {
            return font
        }
        return fallback
    }

    /// NSFontManager's 0–15 weight scale; 5 is Regular, 9 is Bold.
    static func fontManagerWeight(_ weight: NSFont.Weight) -> Int {
        switch weight {
        case .ultraLight: return 1
        case .thin: return 2
        case .light: return 3
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .heavy: return 11
        case .black: return 14
        default: return 5
        }
    }

    static func matchesFamily(_ font: NSFont, _ familyName: String) -> Bool {
        if font.familyName == familyName { return true }
        let compactFamily = familyName.replacingOccurrences(of: " ", with: "")
        let compactFont = (font.familyName ?? font.fontName)
            .replacingOccurrences(of: " ", with: "")
        return compactFont.localizedCaseInsensitiveContains(compactFamily)
    }
}

private struct AppFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let monospacedDigit: Bool
    let mono: Bool
    @AppStorage(AppSettings.fontFamilyKey) private var storedChoice = AppFontChoice.system.rawValue

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        if mono {
            return Typography.mono(size: size, weight: weight)
        }
        var font = Typography.font(
            size: size,
            weight: weight,
            choice: AppFontChoice.resolved(storedChoice)
        )
        if monospacedDigit {
            font = font.monospacedDigit()
        }
        return font
    }
}

extension View {
    func appFont(
        _ role: Typography.Role,
        weight: Font.Weight? = nil,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(AppFontModifier(
            size: role.size,
            weight: weight ?? role.weight,
            monospacedDigit: monospacedDigit,
            mono: false
        ))
    }

    func appFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(AppFontModifier(
            size: size,
            weight: weight,
            monospacedDigit: false,
            mono: false
        ))
    }

    func appMonoFont(_ role: Typography.Role, weight: Font.Weight? = nil) -> some View {
        modifier(AppFontModifier(
            size: role.size,
            weight: weight ?? role.weight,
            monospacedDigit: false,
            mono: true
        ))
    }

    func appMonoFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(AppFontModifier(
            size: size,
            weight: weight,
            monospacedDigit: false,
            mono: true
        ))
    }
}

/// In-process checks for the font catalog. Invoked by `DosaCalendarChecks`
/// because this repo has no XCTest.
public enum TypographySelfChecks {
    public static func run() -> Int {
        var failures = 0
        func expect(_ condition: Bool, _ message: String, line: Int = #line) {
            if !condition {
                failures += 1
                fputs("FAIL Typography.swift:\(line): \(message)\n", stderr)
            }
        }

        expect(AppFontChoice.allCases.count == 10, "catalog should list 10 faces")
        expect(
            Set(AppFontChoice.allCases.map(\.rawValue)).count == AppFontChoice.allCases.count,
            "raw values should be unique"
        )
        expect(
            Set(AppFontChoice.allCases.map(\.displayName)).count == AppFontChoice.allCases.count,
            "display names should be unique"
        )
        expect(AppFontChoice.resolved("") == .system, "empty stored value should default to System")
        expect(AppFontChoice.resolved("not-a-font") == .system, "unknown stored value should default to System")
        expect(AppFontChoice.resolved(AppFontChoice.charter.rawValue) == .charter, "known raw value should round-trip")

        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: AppSettings.fontFamilyKey)
        defaults.removeObject(forKey: AppSettings.fontFamilyKey)
        expect(AppSettings.currentFontChoice == .system, "unset preference should be System")
        defaults.set(AppFontChoice.palatino.rawValue, forKey: AppSettings.fontFamilyKey)
        expect(AppSettings.currentFontChoice == .palatino, "stored preference should resolve")
        defaults.set("comic-sans-ms", forKey: AppSettings.fontFamilyKey)
        expect(AppSettings.currentFontChoice == .system, "garbage preference should fall back to System")
        if let saved {
            defaults.set(saved, forKey: AppSettings.fontFamilyKey)
        } else {
            defaults.removeObject(forKey: AppSettings.fontFamilyKey)
        }

        let mono = Typography.nsMono(size: 12)
        expect(mono.isFixedPitch, "semantic mono should be fixed-pitch")
        let bodyMono = Typography.nsMono(size: Typography.Role.body.size)
        expect(bodyMono.isFixedPitch, "body mono should be fixed-pitch")

        let system = Typography.nsFont(size: 14, choice: .system)
        expect(
            abs(system.pointSize - 14) < 0.01,
            "system font should keep the requested size"
        )
        expect(
            Typography.matchesFamily(system, system.familyName ?? ".AppleSystemUIFont")
                || system.fontName.contains("SF"),
            "system choice should resolve to the system face"
        )

        let missing = Typography.resolvedNSFont(
            size: 16,
            weight: .regular,
            familyName: "DefinitelyNoSuchFamily-xyz",
            design: nil
        )
        let fallback = NSFont.systemFont(ofSize: 16, weight: .regular)
        expect(
            missing.fontName == fallback.fontName,
            "unavailable family should fall back to the system font"
        )

        for choice in AppFontChoice.allCases {
            let font = Typography.nsFont(size: 14, weight: .regular, choice: choice)
            expect(abs(font.pointSize - 14) < 0.01, "\(choice.displayName) should keep size 14")
            if let family = choice.familyName,
               NSFontManager.shared.availableFontFamilies.contains(family) {
                expect(
                    Typography.matchesFamily(font, family),
                    "\(choice.displayName) should resolve to family \(family), got \(font.familyName ?? font.fontName)"
                )
            }
        }

        let fingerprint = Theme.styleFingerprint
        expect(
            fingerprint.contains(AppSettings.currentFontChoice.rawValue),
            "style fingerprint should include the current font choice"
        )

        return failures
    }
}
