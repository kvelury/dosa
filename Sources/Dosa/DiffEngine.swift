import Foundation
import SwiftUI

/// Deterministic diff between the user's sparse manual notes and the LLM-enhanced
/// markdown. Tokens that survive from the manual notes render in the primary text
/// color; everything the AI injected around them renders in the accent color.
enum DiffEngine {
    /// The color for Dosa's additions, per the user's Settings choice. Each option
    /// is darker in light mode and brighter in dark mode so it stays readable.
    static func color(named name: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch name {
            case "Purple":
                return isDark
                    ? NSColor(red: 0.78, green: 0.62, blue: 0.98, alpha: 1)
                    : NSColor(red: 0.45, green: 0.27, blue: 0.65, alpha: 1)
            case "Red":
                return isDark
                    ? NSColor(red: 0.96, green: 0.55, blue: 0.55, alpha: 1)
                    : NSColor(red: 0.72, green: 0.18, blue: 0.18, alpha: 1)
            case "Dark Blue":
                return isDark
                    ? NSColor(red: 0.55, green: 0.70, blue: 1.00, alpha: 1)
                    : NSColor(red: 0.13, green: 0.28, blue: 0.62, alpha: 1)
            case "Dark Green":
                return isDark
                    ? NSColor(red: 0.50, green: 0.85, blue: 0.60, alpha: 1)
                    : NSColor(red: 0.10, green: 0.42, blue: 0.22, alpha: 1)
            default:
                return isDark
                    ? NSColor(white: 0.68, alpha: 1)
                    : NSColor(white: 0.42, alpha: 1)
            }
        }
    }

    static var aiNSColor: NSColor {
        color(named: AppSettings.currentDosaColorName)
    }

    static var aiColor: Color {
        Color(nsColor: aiNSColor)
    }

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            if character == "\n" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                tokens.append("\n")
            } else if character == " " || character == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    static func attributedDiff(manual: String, enhanced: String) -> AttributedString {
        let manualTokens = tokenize(manual)
        let enhancedTokens = tokenize(enhanced)

        var insertedOffsets = Set<Int>()
        let difference = enhancedTokens.difference(from: manualTokens)
        for case let .insert(offset, _, _) in difference.insertions {
            insertedOffsets.insert(offset)
        }

        var result = AttributedString()
        var lastWasNewline = true
        var headingLevel: Int?
        for (offset, token) in enhancedTokens.enumerated() {
            if token == "\n" {
                result += AttributedString("\n")
                lastWasNewline = true
                headingLevel = nil
                continue
            }
            if lastWasNewline, (1...6).contains(token.count), token.allSatisfy({ $0 == "#" }) {
                headingLevel = token.count
            }
            var piece = AttributedString((lastWasNewline ? "" : " ") + token)
            piece.foregroundColor = insertedOffsets.contains(offset) ? aiColor : .primary
            if let level = headingLevel {
            piece.font = Typography.font(size: headingFontSize(level: level), weight: .bold)
            }
            result += piece
            lastWasNewline = false
        }
        return result
    }

    private static func headingFontSize(level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 18
        case 3: return 16
        default: return 14.5
        }
    }
}
