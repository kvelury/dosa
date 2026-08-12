import SwiftUI

struct GlobalSearchView: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var search: SearchCoordinator
    @Binding var selectedNoteId: UUID?
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var enabledFields: Set<SearchField> = SearchService.allFields
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [SearchMatch] {
        guard trimmedQuery.count >= 2 else { return [] }
        return SearchService.globalMatches(notes: store.activeNotes, query: trimmedQuery, fields: enabledFields)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search all notes and transcripts", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                Button("Done") {
                    dismiss()
                }
            }
            .padding()

            SearchFieldToggleRow(
                fields: [.title, .transcript, .manual, .enhanced],
                enabledFields: $enabledFields
            )
            .padding(.horizontal)
            .padding(.bottom, 10)

            Divider()

            content
        }
        .frame(width: 640, height: 540)
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var content: some View {
        if enabledFields.isEmpty {
            placeholder("Select at least one filter to search.")
        } else if trimmedQuery.count < 2 {
            placeholder("Type at least 2 characters to search across titles, notes, Dosa notes, and transcripts.")
        } else if results.isEmpty {
            placeholder("No matches for “\(trimmedQuery)”.")
        } else {
            List(results) { match in
                Button {
                    jump(to: match)
                } label: {
                    SearchResultRow(match: match, query: trimmedQuery, showTitle: true)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }

    private func placeholder(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func jump(to match: SearchMatch) {
        selectedNoteId = match.noteId
        search.pendingReveal = SearchCoordinator.Reveal(
            id: UUID(),
            noteId: match.noteId,
            field: match.field,
            location: match.range.location,
            length: match.range.length
        )
        dismiss()
    }
}

struct NoteSearchView: View {
    @EnvironmentObject private var search: SearchCoordinator
    let note: Note
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var enabledFields: Set<SearchField> = [.transcript, .manual, .enhanced]
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var results: [SearchMatch] {
        guard trimmedQuery.count >= 2 else { return [] }
        return SearchService.matches(in: note, query: trimmedQuery, fields: enabledFields, maxPerField: 20)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search this note and transcript", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(10)

            SearchFieldToggleRow(
                fields: [.transcript, .manual, .enhanced],
                enabledFields: $enabledFields
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            if enabledFields.isEmpty {
                Text("Select at least one filter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if trimmedQuery.count < 2 {
                Text("Type at least 2 characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                Text("No matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { match in
                    Button {
                        jump(to: match)
                    } label: {
                        SearchResultRow(match: match, query: trimmedQuery, showTitle: false)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 420, height: 330)
        .onAppear { searchFocused = true }
    }

    private func jump(to match: SearchMatch) {
        search.pendingReveal = SearchCoordinator.Reveal(
            id: UUID(),
            noteId: match.noteId,
            field: match.field,
            location: match.range.location,
            length: match.range.length
        )
        onDismiss()
    }
}

struct SearchFieldToggleRow: View {
    let fields: [SearchField]
    @Binding var enabledFields: Set<SearchField>

    var body: some View {
        HStack(spacing: 8) {
            ForEach(fields, id: \.self) { field in
                SearchFieldToggle(field: field, enabledFields: $enabledFields)
            }
            Spacer()
        }
    }
}

private struct SearchFieldToggle: View {
    let field: SearchField
    @Binding var enabledFields: Set<SearchField>

    private var isOn: Bool {
        enabledFields.contains(field)
    }

    var body: some View {
        Button {
            if isOn {
                enabledFields.remove(field)
            } else {
                enabledFields.insert(field)
            }
        } label: {
            HStack(spacing: 4) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
                Text(field.rawValue)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.16) : Color.clear))
            .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35)))
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Exclude \(field.rawValue) from the search" : "Include \(field.rawValue) in the search")
    }
}

struct SearchResultRow: View {
    let match: SearchMatch
    let query: String
    let showTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if showTitle {
                    Text(match.noteTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                Text(match.field.rawValue)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(SearchService.attributedSnippet(match.snippet, query: query))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
