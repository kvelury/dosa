import Foundation
import SwiftUI

enum SearchField: String {
    case title = "Title"
    case manual = "My Notes"
    case enhanced = "Dosa Notes"
    case transcript = "Transcript"
}

struct SearchMatch: Identifiable {
    let id = UUID()
    let noteId: UUID
    let noteTitle: String
    let field: SearchField
    let range: NSRange
    let snippet: String
}

/// Carries a "jump to this match" request from search UI to the note editor,
/// which switches to the right view (or opens the transcript popup) and
/// scrolls to / flashes the match.
final class SearchCoordinator: ObservableObject {
    struct Reveal: Equatable {
        let id: UUID
        let noteId: UUID
        let field: SearchField
        let location: Int
        let length: Int
    }

    @Published var pendingReveal: Reveal?
}

enum SearchService {
    static let allFields: Set<SearchField> = [.title, .manual, .enhanced, .transcript]

    static func globalMatches(
        notes: [Note], query: String,
        fields: Set<SearchField> = allFields, maxTotal: Int = 200
    ) -> [SearchMatch] {
        var results: [SearchMatch] = []
        for note in notes {
            results.append(contentsOf: matches(in: note, query: query, fields: fields))
            if results.count >= maxTotal { break }
        }
        return Array(results.prefix(maxTotal))
    }

    static func matches(
        in note: Note, query: String,
        fields: Set<SearchField> = allFields, maxPerField: Int = 8
    ) -> [SearchMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !fields.isEmpty else { return [] }

        var results: [SearchMatch] = []
        if fields.contains(.title), note.displayTitle.range(of: trimmed, options: .caseInsensitive) != nil {
            results.append(SearchMatch(
                noteId: note.id, noteTitle: note.displayTitle, field: .title,
                range: NSRange(location: 0, length: 0), snippet: note.displayTitle
            ))
        }
        if fields.contains(.manual) {
            appendMatches(in: note.manualText, field: .manual, note: note, query: trimmed, maxPerField: maxPerField, into: &results)
        }
        if fields.contains(.enhanced) {
            appendMatches(in: note.enhancedMarkdown, field: .enhanced, note: note, query: trimmed, maxPerField: maxPerField, into: &results)
        }
        if fields.contains(.transcript) {
            appendMatches(in: note.transcript, field: .transcript, note: note, query: trimmed, maxPerField: maxPerField, into: &results)
        }
        return results
    }

    private static func appendMatches(
        in text: String?, field: SearchField, note: Note, query: String,
        maxPerField: Int, into results: inout [SearchMatch]
    ) {
        guard let text, !text.isEmpty else { return }
        let ns = text as NSString
        var location = 0
        var count = 0
        while count < maxPerField, location < ns.length {
            let found = ns.range(of: query, options: .caseInsensitive, range: NSRange(location: location, length: ns.length - location))
            guard found.location != NSNotFound else { break }
            results.append(SearchMatch(
                noteId: note.id, noteTitle: note.displayTitle, field: field,
                range: found, snippet: snippet(around: found, in: ns)
            ))
            count += 1
            location = found.location + max(found.length, 1)
        }
    }

    private static func snippet(around range: NSRange, in text: NSString, context: Int = 36) -> String {
        let start = max(0, range.location - context)
        let end = min(text.length, range.location + range.length + context)
        let safeRange = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        var snippet = text.substring(with: safeRange)
            .replacingOccurrences(of: "\n", with: " ")
        if safeRange.location > 0 { snippet = "…" + snippet }
        if safeRange.location + safeRange.length < text.length { snippet += "…" }
        return snippet
    }

    static func attributedSnippet(_ snippet: String, query: String) -> AttributedString {
        var result = AttributedString()
        let ns = snippet as NSString
        var location = 0
        while location < ns.length {
            let found = ns.range(of: query, options: .caseInsensitive, range: NSRange(location: location, length: ns.length - location))
            if found.location == NSNotFound {
                result += AttributedString(ns.substring(from: location))
                break
            }
            if found.location > location {
                result += AttributedString(ns.substring(with: NSRange(location: location, length: found.location - location)))
            }
            var match = AttributedString(ns.substring(with: found))
            match.inlinePresentationIntent = .stronglyEmphasized
            match.foregroundColor = Theme.current.highlightColor
            result += match
            location = found.location + max(found.length, 1)
        }
        return result
    }
}
