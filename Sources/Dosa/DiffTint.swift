import AppKit

/// Tints every token of the generated notes that does not survive from the
/// user's manual notes, so Dosa's additions read differently from what the user
/// wrote. The distinction is recomputed from the two texts rather than stored —
/// nothing in the note's markdown marks a range as "AI", which is what keeps
/// the storage form plain and the Notion export lossless.
///
/// Runs as the editor engine's `decorate` hook: the engine restyles a paragraph
/// (resetting its colors) and this re-applies the tint over that same range.
enum DiffTint {

    /// Applies the tint to the inserted tokens that fall inside `range`.
    /// `storage` must already hold the generated text; `base` is the manual notes.
    static func apply(base: String, color: NSColor, to storage: NSMutableAttributedString, in range: NSRange) {
        let full = NSRange(location: 0, length: storage.length)
        guard let clamped = range.intersection(full), clamped.length > 0 else { return }
        for tinted in insertedRanges(in: storage.string, base: base) {
            guard let overlap = tinted.intersection(clamped), overlap.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: overlap)
        }
    }

    /// Ranges of `text` holding tokens the diff reports as insertions against
    /// `base`. Cached because one restyle pass decorates several paragraphs and
    /// would otherwise re-diff the whole document for each of them.
    private static func insertedRanges(in text: String, base: String) -> [NSRange] {
        if cachedText == text, cachedBase == base, let cachedRanges {
            return cachedRanges
        }
        let (tokens, ranges) = tokenizeWithRanges(text)
        let baseTokens = DiffEngine.tokenize(base)
        var insertedOffsets = Set<Int>()
        for case let .insert(offset, _, _) in tokens.difference(from: baseTokens).insertions {
            insertedOffsets.insert(offset)
        }
        let result = ranges.enumerated()
            .filter { insertedOffsets.contains($0.offset) && $0.element.length > 0 }
            .map(\.element)
        cachedText = text
        cachedBase = base
        cachedRanges = result
        return result
    }

    private static var cachedText: String?
    private static var cachedBase: String?
    private static var cachedRanges: [NSRange]?

    /// Same tokenization as `DiffEngine.tokenize`, but also returns each token's
    /// NSRange. The two must stay in step or the tint lands on the wrong words.
    private static func tokenizeWithRanges(_ text: String) -> ([String], [NSRange]) {
        var tokens: [String] = []
        var ranges: [NSRange] = []
        var currentStart: String.Index?
        var index = text.startIndex

        func flush(_ end: String.Index) {
            guard let start = currentStart else { return }
            tokens.append(String(text[start..<end]))
            ranges.append(NSRange(start..<end, in: text))
            currentStart = nil
        }

        while index < text.endIndex {
            let character = text[index]
            if character == "\n" {
                flush(index)
                tokens.append("\n")
                ranges.append(NSRange(index..<text.index(after: index), in: text))
            } else if character == " " || character == "\t" {
                flush(index)
            } else if currentStart == nil {
                currentStart = index
            }
            index = text.index(after: index)
        }
        flush(text.endIndex)
        return (tokens, ranges)
    }
}
