import SwiftUI
import AppKit

struct TranscriptView: View {
    @Environment(\.dismiss) private var dismiss
    let note: Note
    var highlight: TextHighlight?

    /// The row a search hit points at, tinted so it can be spotted.
    @State private var highlightedEntryId: Int?

    /// Parsed once at init rather than per render: a long meeting's transcript is
    /// tens of thousands of characters, and the sheet re-renders on every state
    /// change. Nil when the transcript doesn't follow either Dosa format.
    private let parsed: TranscriptParsing.Parsed?

    init(note: Note, highlight: TextHighlight? = nil) {
        self.note = note
        self.highlight = highlight
        let parsed = note.transcript.map(TranscriptParsing.parse)
        self.parsed = parsed?.isStructured == true ? parsed : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Full Transcript", systemImage: "text.bubble")
                    .appFont(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.transcript ?? "", forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            if let parsed {
                rows(parsed)
            } else {
                // Imported or hand-edited transcripts that don't follow either
                // Dosa format still get shown, just without the row treatment.
                DosaMarkdownEditor(
                    text: .constant(note.transcript ?? "No transcript yet. Record the meeting and click Generate Notes first."),
                    isEditable: false,
                    highlight: highlight,
                    documentId: "\(note.id)-transcript"
                )
                .accessibilityLabel("Transcript")
            }
        }
        .frame(minWidth: 560, idealWidth: 660, maxWidth: 900, minHeight: 460, idealHeight: 620, maxHeight: 900)
        .appFontScope()
        .dismissesOnOutsideClick()
    }

    private func rows(_ parsed: TranscriptParsing.Parsed) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(parsed.entries) { entry in
                        TranscriptRowView(
                            speaker: entry.speaker,
                            start: entry.start,
                            text: entry.text
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(entry.id == highlightedEntryId
                                      ? Theme.current.accentColor.opacity(0.18)
                                      : .clear)
                        )
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .accessibilityLabel("Transcript")
            .onAppear { reveal(highlight, in: parsed, proxy: proxy) }
            .onChange(of: highlight) { _, newValue in
                reveal(newValue, in: parsed, proxy: proxy)
            }
        }
    }

    /// Maps a search hit's character range onto the row that contains it — the
    /// sheet renders rows rather than one text run, so the range can't be applied
    /// directly the way `DosaMarkdownEditor` does it.
    private func reveal(
        _ highlight: TextHighlight?,
        in parsed: TranscriptParsing.Parsed,
        proxy: ScrollViewProxy
    ) {
        guard let highlight,
              let entry = parsed.entries.first(where: { $0.contains(location: highlight.range.location) })
                ?? parsed.entries.last(where: { $0.sourceOffset <= highlight.range.location })
        else { return }
        highlightedEntryId = entry.id
        proxy.scrollTo(entry.id, anchor: .center)
    }
}
