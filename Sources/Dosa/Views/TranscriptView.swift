import SwiftUI
import AppKit

struct TranscriptView: View {
    @Environment(\.dismiss) private var dismiss
    let note: Note
    var highlight: TextHighlight?

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

            MarkdownTextEditor(
                text: .constant(note.transcript ?? "No transcript yet. Record the meeting and click Generate Notes first."),
                isEditable: false,
                highlight: highlight
            )
            .accessibilityLabel("Transcript")
        }
        .frame(minWidth: 560, idealWidth: 660, maxWidth: 900, minHeight: 460, idealHeight: 620, maxHeight: 900)
        .appFontScope()
    }
}
