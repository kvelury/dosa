import Foundation

/// Reads a stored transcript back into rows so the Full Transcript sheet can show
/// the same speaker/timestamp treatment as the live pane.
///
/// Every transcript Dosa writes is one of two shapes:
///   - `**Speaker** [mm:ss]: text` — live mode, Apple's two-track path, and
///     Gemini (its prompt mandates this format, see `AppSettings.defaultTranscriptPrompt`)
///   - `[mm:ss] text` — older recordings transcribed from the mixed file only
/// Anything else is kept verbatim as a row with no header, and a transcript that
/// mostly fails to parse is rendered as plain text instead.
enum TranscriptParsing {

    struct Entry: Identifiable {
        /// The entry's offset in the source transcript — unique per entry, and
        /// stable across re-parses of the same transcript, so scroll targets and
        /// the highlighted row survive a re-render.
        var id: Int { sourceOffset }
        let speaker: String?
        let start: TimeInterval?
        var text: String
        /// Character offset of this entry's first line in the source transcript,
        /// so a search hit's range can be mapped back to the row showing it.
        let sourceOffset: Int
        /// Length of the source text this entry covers, including the newline
        /// that separates it from the next one.
        var sourceLength: Int

        func contains(location: Int) -> Bool {
            location >= sourceOffset && location < sourceOffset + sourceLength
        }
    }

    struct Parsed {
        let entries: [Entry]
        /// True when enough lines carried a recognizable header to be worth
        /// rendering as rows rather than as the raw markdown.
        let isStructured: Bool
    }

    private static let labeled = try? NSRegularExpression(
        pattern: #"^\*\*(.+?)\*\*\s*\[(\d+):(\d{2})\]\s*:?\s*(.*)$"#
    )
    private static let timestampOnly = try? NSRegularExpression(
        pattern: #"^\[(\d+):(\d{2})\]\s*(.*)$"#
    )

    static func parse(_ transcript: String) -> Parsed {
        var entries: [Entry] = []
        var recognized = 0
        var nonEmpty = 0
        var offset = 0

        for line in transcript.components(separatedBy: "\n") {
            // +1 for the newline that `components` consumed. The last line
            // overcounts by one, which only ever widens the final row's range.
            let lineLength = line.utf16.count + 1
            defer { offset += lineLength }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                // Blank lines separate entries; they carry no text of their own,
                // so charge their length to the entry above to keep offsets exact.
                if !entries.isEmpty {
                    entries[entries.count - 1].sourceLength += lineLength
                }
                continue
            }
            nonEmpty += 1

            if let match = firstMatch(labeled, in: trimmed) {
                recognized += 1
                entries.append(Entry(
                    speaker: match.groups[0],
                    start: seconds(minutes: match.groups[1], seconds: match.groups[2]),
                    text: match.groups[3],
                    sourceOffset: offset,
                    sourceLength: lineLength
                ))
            } else if let match = firstMatch(timestampOnly, in: trimmed) {
                recognized += 1
                entries.append(Entry(
                    speaker: nil,
                    start: seconds(minutes: match.groups[0], seconds: match.groups[1]),
                    text: match.groups[2],
                    sourceOffset: offset,
                    sourceLength: lineLength
                ))
            } else if !entries.isEmpty, entries[entries.count - 1].speaker != nil || entries[entries.count - 1].start != nil {
                // A wrapped continuation of the line above (some transcripts put
                // a speaker's paragraph across several lines).
                entries[entries.count - 1].text += "\n" + trimmed
                entries[entries.count - 1].sourceLength += lineLength
            } else {
                entries.append(Entry(
                    speaker: nil,
                    start: nil,
                    text: trimmed,
                    sourceOffset: offset,
                    sourceLength: lineLength
                ))
            }
        }

        // Half the lines is a deliberately loose bar: a transcript with a stray
        // header or a few unlabeled asides still reads far better as rows.
        let structured = nonEmpty > 0 && recognized * 2 >= nonEmpty
        return Parsed(entries: entries, isStructured: structured)
    }

    private struct Match {
        let groups: [String]
    }

    private static func firstMatch(_ regex: NSRegularExpression?, in line: String) -> Match? {
        guard let regex else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else { return nil }
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let groupRange = Range(match.range(at: index), in: line) else {
                groups.append("")
                continue
            }
            groups.append(String(line[groupRange]).trimmingCharacters(in: .whitespaces))
        }
        return Match(groups: groups)
    }

    /// Minutes are unbounded — a two-hour meeting's last line reads `[128:04]`.
    private static func seconds(minutes: String, seconds: String) -> TimeInterval? {
        guard let minutes = Double(minutes), let seconds = Double(seconds) else { return nil }
        return minutes * 60 + seconds
    }
}
