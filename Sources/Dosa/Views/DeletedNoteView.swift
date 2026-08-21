import SwiftUI

struct DeletedNoteView: View {
    @EnvironmentObject private var store: NotesStore
    @AppStorage(AppSettings.themeKey) private var themeName = "Classic"
    let noteId: UUID
    @Binding var selectedNoteId: UUID?
    @State private var confirmDelete = false

    var body: some View {
        if let note = store.note(id: noteId) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Label(
                        "In Deleted Notes — permanently removed in \(store.daysRemaining(for: note)) days",
                        systemImage: "trash"
                    )
                    .font(.callout)
                    Spacer()
                    Button("Restore") {
                        store.restore(noteId)
                    }
                    Button("Delete Permanently", role: .destructive) {
                        confirmDelete = true
                    }
                }
                .padding(12)
                .background(.yellow.opacity(0.12))

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(note.displayTitle)
                            .font(.system(size: 26, weight: .bold))
                        Text(note.createdAt, style: .date)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Divider()
                        Text(previewText(note))
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                }
            }
            .background(Theme.current.editorBackgroundColor)
            .confirmationDialog("Permanently delete this note?", isPresented: $confirmDelete) {
                Button("Yes, Delete Forever", role: .destructive) {
                    selectedNoteId = nil
                    store.deletePermanently(noteId)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The note, its transcript, and its recording will be gone forever. This cannot be undone.")
            }
        } else {
            HomeView()
        }
    }

    private func previewText(_ note: Note) -> String {
        if !note.manualText.isEmpty { return note.manualText }
        if let enhanced = note.enhancedMarkdown { return enhanced }
        return "(empty note)"
    }
}
