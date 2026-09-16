import Foundation

/// Markdown formatting as pure text transforms — given the document and a
/// selection, each action returns the replacement to make and where the
/// selection lands afterwards. Keeping them free of AppKit is what makes them
/// testable; `MarkdownFormattingCommand` is the thin layer that applies one to
/// a live text view.
enum MarkdownFormatting {

    /// One edit: swap `range` for `replacement`, then select `selection`.
    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
        let selection: NSRange
    }

    enum InlineStyle: String {
        case bold = "**"
        case italic = "_"
        case strikethrough = "~~"
        case code = "`"

        var marker: String { rawValue }
    }

    enum BlockStyle: Equatable {
        case heading(Int)
        case bulletList
        case numberedList
        case taskList
        case blockquote
    }

    static let indentUnit = "    "

    // MARK: - Inline

    /// Wraps the selection in `style`'s markers, or unwraps it when it is
    /// already wrapped. With an empty selection the markers are inserted and the
    /// caret is placed between them, ready to type into.
    static func toggleInline(_ style: InlineStyle, in text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }
        let marker = style.marker
        let markerLength = (marker as NSString).length

        // Selection covers the markers themselves: "**bold**" selected.
        if selection.length >= 2 * markerLength {
            let selected = ns.substring(with: selection)
            if selected.hasPrefix(marker), selected.hasSuffix(marker) {
                let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
                return Edit(
                    range: selection,
                    replacement: inner,
                    selection: NSRange(location: selection.location, length: (inner as NSString).length)
                )
            }
        }

        // Markers sit just outside the selection: "bold" selected inside "**bold**".
        let outer = NSRange(
            location: selection.location - markerLength,
            length: selection.length + 2 * markerLength
        )
        if outer.location >= 0, NSMaxRange(outer) <= ns.length {
            let surrounding = ns.substring(with: outer)
            if surrounding.hasPrefix(marker), surrounding.hasSuffix(marker) {
                let inner = ns.substring(with: selection)
                return Edit(
                    range: outer,
                    replacement: inner,
                    selection: NSRange(location: outer.location, length: (inner as NSString).length)
                )
            }
        }

        let selected = ns.substring(with: selection)
        let replacement = marker + selected + marker
        let selectionAfter = selection.length == 0
            ? NSRange(location: selection.location + markerLength, length: 0)
            : NSRange(location: selection.location + markerLength, length: selection.length)
        return Edit(range: selection, replacement: replacement, selection: selectionAfter)
    }

    /// Wraps the selection as a link, or inserts an empty one. The caret lands
    /// in the URL slot, which is what you want to fill in next.
    static func insertLink(in text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }
        let label = ns.substring(with: selection)
        let replacement = "[\(label)]()"
        let caret = selection.location + (("[\(label)](" as NSString).length)
        return Edit(
            range: selection,
            replacement: replacement,
            selection: NSRange(location: caret, length: 0)
        )
    }

    // MARK: - Block

    /// Applies `style` to every line the selection touches, or strips it when
    /// all of those lines already carry it.
    static func toggleBlock(_ style: BlockStyle, in text: String, selection: NSRange) -> Edit? {
        let ns = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }
        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }
        if lines.isEmpty { lines = [""] }

        let contentful = lines.enumerated().filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
        let targets = contentful.isEmpty ? Array(lines.enumerated()) : contentful
        let removing = targets.allSatisfy { hasPrefix(style, on: $0.element) }

        var counter = 1
        for (index, line) in lines.enumerated() {
            let isTarget = targets.contains { $0.offset == index }
            guard isTarget else { continue }
            let (indent, body) = splitIndent(line)
            let stripped = strippingAnyBlockPrefix(body)
            if removing {
                lines[index] = indent + stripped
            } else {
                lines[index] = indent + prefix(style, number: counter) + stripped
                counter += 1
            }
        }

        var replacement = lines.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }
        guard replacement != block else { return nil }
        return Edit(
            range: lineRange,
            replacement: replacement,
            selection: NSRange(location: lineRange.location, length: (replacement as NSString).length)
        )
    }

    /// Indents or outdents every line the selection touches by one unit. An
    /// empty selection on a non-list line just gets spaces at the caret.
    static func indent(in text: String, selection: NSRange, outdent: Bool) -> Edit? {
        let ns = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }

        if !outdent, selection.length == 0 {
            let currentLine = ns.substring(with: ns.lineRange(for: selection))
            if !isListItem(currentLine) {
                return Edit(
                    range: selection,
                    replacement: indentUnit,
                    selection: NSRange(
                        location: selection.location + (indentUnit as NSString).length,
                        length: 0
                    )
                )
            }
        }

        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }

        var firstLineDelta = 0
        for (index, line) in lines.enumerated() {
            if outdent {
                var trimmed = line
                var removed = 0
                while removed < indentUnit.count, trimmed.hasPrefix(" ") {
                    trimmed.removeFirst()
                    removed += 1
                }
                if removed == 0, trimmed.hasPrefix("\t") {
                    trimmed.removeFirst()
                    removed = 1
                }
                lines[index] = trimmed
                if index == 0 { firstLineDelta = -removed }
            } else if !line.isEmpty {
                lines[index] = indentUnit + line
                if index == 0 { firstLineDelta = indentUnit.count }
            }
        }

        var replacement = lines.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }
        guard replacement != block else { return nil }

        let selectionAfter: NSRange
        if selection.length == 0 {
            let location = max(lineRange.location, selection.location + firstLineDelta)
            selectionAfter = NSRange(location: location, length: 0)
        } else {
            selectionAfter = NSRange(
                location: lineRange.location,
                length: (replacement as NSString).length
            )
        }
        return Edit(range: lineRange, replacement: replacement, selection: selectionAfter)
    }

    // MARK: - Line prefixes

    private static let listMarker = try! NSRegularExpression(
        pattern: #"^([-*+]|\d+\.)\s+(\[[ xX]\]\s+)?"#
    )
    private static let headingMarker = try! NSRegularExpression(pattern: #"^#{1,6}\s+"#)
    private static let quoteMarker = try! NSRegularExpression(pattern: #"^>\s?"#)

    private static func prefix(_ style: BlockStyle, number: Int) -> String {
        switch style {
        case .heading(let level): return String(repeating: "#", count: max(1, min(6, level))) + " "
        case .bulletList: return "- "
        case .numberedList: return "\(number). "
        case .taskList: return "- [ ] "
        case .blockquote: return "> "
        }
    }

    private static func hasPrefix(_ style: BlockStyle, on line: String) -> Bool {
        let (_, body) = splitIndent(line)
        let ns = body as NSString
        let full = NSRange(location: 0, length: ns.length)
        switch style {
        case .heading(let level):
            guard let match = headingMarker.firstMatch(in: body, range: full) else { return false }
            return ns.substring(with: match.range).filter { $0 == "#" }.count == level
        case .bulletList:
            guard let match = listMarker.firstMatch(in: body, range: full) else { return false }
            // A task item is a bullet with a box; toggling "bullet" should not
            // claim it, or the box would vanish on a no-op press.
            return match.range(at: 2).location == NSNotFound
                && !ns.substring(with: match.range(at: 1)).hasSuffix(".")
        case .numberedList:
            guard let match = listMarker.firstMatch(in: body, range: full) else { return false }
            return ns.substring(with: match.range(at: 1)).hasSuffix(".")
        case .taskList:
            guard let match = listMarker.firstMatch(in: body, range: full) else { return false }
            return match.range(at: 2).location != NSNotFound
        case .blockquote:
            return quoteMarker.firstMatch(in: body, range: full) != nil
        }
    }

    /// Drops whichever block marker the line starts with, so switching between
    /// styles replaces rather than stacks them.
    private static func strippingAnyBlockPrefix(_ body: String) -> String {
        let ns = body as NSString
        let full = NSRange(location: 0, length: ns.length)
        for regex in [headingMarker, quoteMarker, listMarker] {
            if let match = regex.firstMatch(in: body, range: full), match.range.length > 0 {
                return ns.substring(from: NSMaxRange(match.range))
            }
        }
        return body
    }

    private static func splitIndent(_ line: String) -> (indent: String, body: String) {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return (String(indent), String(line.dropFirst(indent.count)))
    }

    private static func isListItem(_ line: String) -> Bool {
        let (_, body) = splitIndent(line)
        return listMarker.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) != nil
    }
}
