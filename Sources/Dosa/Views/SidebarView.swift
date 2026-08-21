import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var templates: TemplateStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updater: UpdateManager
    @Binding var selectedNoteIds: Set<UUID>

    @State private var newFolderParentId: UUID?
    @State private var newFolderName = ""
    @State private var showNewFolderAlert = false
    @State private var confirmEmptyTrash = false
    @State private var pendingDeleteIds: Set<UUID> = []
    @State private var deletedNotesExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    promptNewFolder(nil)
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("New folder")
                .accessibilityLabel("New folder")
                Button {
                    appState.showGlobalSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .help("Search all notes and transcripts (⌘K)")
                .accessibilityLabel("Search all notes and transcripts")
                Spacer()
                // Split into a button and a menu because a Menu's own control
                // metrics win over its label's font, and its built-in indicator
                // sits too far from the glyph to size or space explicitly.
                HStack(spacing: 5) {
                    Button {
                        let note = store.createNote()
                        selectedNoteIds = [note.id]
                    } label: {
                        Image(systemName: "plus")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 15, height: 15)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .help("New note (⌘N)")
                    .accessibilityLabel("New note")
                    Menu {
                        Button("New Note") {
                            let note = store.createNote()
                            selectedNoteIds = [note.id]
                        }
                        Button("Import Audio or Video…") {
                            importIntoNewNote(folderId: nil)
                        }
                        if !templates.templates.isEmpty {
                            Divider()
                            Section("Templates") {
                                ForEach(templates.templates) { template in
                                    Button(template.name) {
                                        let note = store.createNote(template: template)
                                        selectedNoteIds = [note.id]
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 8, height: 8)
                            .fontWeight(.regular)
                            .frame(width: 20, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("New note from a template, or import audio")
                    .accessibilityLabel("New note from template, or import audio")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16, weight: .medium)) // system-font: sizes the SF Symbols in this toolbar row
            .foregroundStyle(Theme.secondaryTextColor)
            .padding(.horizontal, 14)
            .padding(.top, 34)
            // Enough of a gap that the "Notes" section header reads as the top of
            // the list rather than a caption under the toolbar buttons.
            .padding(.bottom, 20)

            notesList

            Divider()

            HStack(spacing: 8) {
                Button {
                    appState.showSettings = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .medium))
                        Text("Settings")
                            .appFont(size: 14)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .help("LLM provider API key, prompts, and app options")
                // minLength keeps the version off the label at the sidebar's
                // 230pt minimum width.
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    if updater.available != nil {
                        Button {
                            appState.showSettings = true
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.current.accentColor)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("An update is available — open Settings to install it")
                        .accessibilityLabel("Update available — open Settings to install")
                    }
                    Text("v\(BuildInfo.shortVersion)")
                        .appFont(.caption2)
                        .foregroundStyle(Theme.tertiaryTextColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("New Folder", isPresented: $showNewFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    store.createFolder(name: name, parentId: newFolderParentId)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            pendingDeleteIds.count == 1 ? "Delete this note?" : "Delete \(pendingDeleteIds.count) notes?",
            isPresented: Binding(
                get: { !pendingDeleteIds.isEmpty },
                set: { presented in
                    if !presented { pendingDeleteIds = [] }
                }
            )
        ) {
            Button("Yes, Delete", role: .destructive) {
                for id in pendingDeleteIds {
                    store.moveToTrash(id)
                }
                selectedNoteIds.subtract(pendingDeleteIds)
                pendingDeleteIds = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notes, transcripts, and recordings move to Deleted Notes, and are permanently removed after \(NotesStore.trashRetentionDays) days.")
        }
        .confirmationDialog(
            "Permanently delete everything in Deleted Notes?",
            isPresented: $confirmEmptyTrash
        ) {
            Button("Yes, Delete All", role: .destructive) {
                selectedNoteIds = selectedNoteIds.filter { store.note(id: $0)?.isDeleted != true }
                store.emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Notes, transcripts, and recordings will be gone forever. This cannot be undone.")
        }
    }

    private var notesList: some View {
        List(selection: $selectedNoteIds) {
            if !store.pinnedNotes.isEmpty {
                Section {
                    ForEach(store.pinnedNotes) { note in
                        NoteRow(
                            note: note,
                            selectedNoteIds: $selectedNoteIds,
                            onRequestDelete: requestDelete
                        )
                    }
                } header: {
                    Text("Pinned").appFont(.caption, weight: .semibold)
                }
            }

            Section {
                ForEach(store.subfolders(of: nil)) { folder in
                    FolderRow(
                        folder: folder,
                        selectedNoteIds: $selectedNoteIds,
                        onNewFolder: promptNewFolder,
                        onImport: importIntoNewNote,
                        onRequestDelete: requestDelete
                    )
                }
                ForEach(store.notes(in: nil)) { note in
                    NoteRow(
                        note: note,
                        selectedNoteIds: $selectedNoteIds,
                        onRequestDelete: requestDelete
                    )
                }
                if store.activeNotes.isEmpty && store.folders.isEmpty {
                    Text("No notes yet — click +")
                        .appFont(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
            } header: {
                RootDropHeader()
            }

            Section {
                DisclosureGroup(isExpanded: $deletedNotesExpanded) {
                    ForEach(store.deletedNotes) { note in
                        DeletedNoteRow(note: note, selectedNoteIds: $selectedNoteIds)
                    }
                    if store.deletedNotes.isEmpty {
                        Text("Empty")
                            .appFont(.callout)
                            .foregroundStyle(Theme.secondaryTextColor)
                    } else {
                        Button {
                            confirmEmptyTrash = true
                        } label: {
                            Label("Empty Deleted Notes…", systemImage: "trash.slash")
                                .foregroundStyle(Theme.current.dangerTextColor)
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    // A real Button, not a tap-gesture-only label, so the
                    // disclosure is reachable by keyboard/VoiceOver (Space to
                    // toggle) as well as by mouse.
                    Button {
                        deletedNotesExpanded.toggle()
                    } label: {
                        Label("Deleted Notes", systemImage: "trash")
                            .appFont(size: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
                }
            } footer: {
                if !store.deletedNotes.isEmpty {
                    Text("Deleted notes are removed permanently after \(NotesStore.trashRetentionDays) days.")
                        .appFont(.caption2)
                        .foregroundStyle(Theme.tertiaryTextColor)
                }
            }
        }
        .listStyle(.sidebar)
        .background(SidebarDeselectCatcher { selectedNoteIds = [] })
    }

    /// Picks a file first, so cancelling the panel doesn't leave an empty note behind.
    /// The editor performs the import when it appears.
    private func importIntoNewNote(folderId: UUID?) {
        guard let url = RecordingImporter.pickFile(for: .newNote) else { return }
        let note = store.createNote(in: folderId)
        appState.pendingNoteAction = PendingNoteAction(noteId: note.id, kind: .importFile(url))
        selectedNoteIds = [note.id]
    }

    private func promptNewFolder(_ parentId: UUID?) {
        newFolderParentId = parentId
        newFolderName = ""
        showNewFolderAlert = true
    }

    private func requestDelete(_ ids: Set<UUID>) {
        pendingDeleteIds = ids
    }
}

/// The "Notes" section header doubles as the drop zone for dragging notes
/// OUT of folders, back to the top level.
private struct RootDropHeader: View {
    @EnvironmentObject private var store: NotesStore
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            Text("Notes")
            if isDropTargeted {
                Text("— drop to move out of folder")
                    .foregroundStyle(Theme.current.accentTextColor)
            }
            Spacer()
        }
        .appFont(.caption, weight: .semibold)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.25) : Color.clear)
        )
        .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
                return false
            }
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let payload = object as? String else { return }
                let ids = payload.components(separatedBy: ",").compactMap(UUID.init(uuidString:))
                guard !ids.isEmpty else { return }
                DispatchQueue.main.async {
                    store.move(noteIds: Set(ids), to: nil)
                }
            }
            return true
        }
    }
}

private struct FolderRow: View {
    @EnvironmentObject private var store: NotesStore
    let folder: Folder
    @Binding var selectedNoteIds: Set<UUID>
    let onNewFolder: (UUID?) -> Void
    let onImport: (UUID?) -> Void
    let onRequestDelete: (Set<UUID>) -> Void

    @State private var isDropTargeted = false
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(store.subfolders(of: folder.id)) { subfolder in
                FolderRow(
                    folder: subfolder,
                    selectedNoteIds: $selectedNoteIds,
                    onNewFolder: onNewFolder,
                    onImport: onImport,
                    onRequestDelete: onRequestDelete
                )
            }
            ForEach(store.notes(in: folder.id)) { note in
                NoteRow(
                    note: note,
                    selectedNoteIds: $selectedNoteIds,
                    onRequestDelete: onRequestDelete
                )
            }
        } label: {
            // A real Button, not a tap-gesture-only label, so the disclosure is
            // reachable by keyboard/VoiceOver as well as by mouse.
            Button {
                isExpanded.toggle()
            } label: {
                Label(folder.name, systemImage: "folder")
                    .appFont(size: 14)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.25) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .contextMenu {
                    Button("New Note in \"\(folder.name)\"") {
                        let note = store.createNote(in: folder.id)
                        selectedNoteIds = [note.id]
                    }
                    Button("Import into \"\(folder.name)\"…") {
                        onImport(folder.id)
                    }
                    Button("New Subfolder…") {
                        onNewFolder(folder.id)
                    }
                    Divider()
                    Button("Delete Folder", role: .destructive) {
                        store.deleteFolder(folder.id)
                    }
                }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        let folderId = folder.id
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let payload = object as? String else { return }
            let ids = payload.components(separatedBy: ",").compactMap(UUID.init(uuidString:))
            guard !ids.isEmpty else { return }
            DispatchQueue.main.async {
                store.move(noteIds: Set(ids), to: folderId)
            }
        }
        return true
    }
}

private struct NoteRow: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var generator: GenerationManager
    let note: Note
    @Binding var selectedNoteIds: Set<UUID>
    let onRequestDelete: (Set<UUID>) -> Void

    /// The notes an action applies to: the whole selection when this row is
    /// part of it, otherwise just this row.
    private var targetIds: Set<UUID> {
        selectedNoteIds.contains(note.id) ? selectedNoteIds : [note.id]
    }

    private var targetsAllPinned: Bool {
        targetIds.allSatisfy { store.note(id: $0)?.isPinned == true }
    }

    private var statusSummary: String {
        var parts: [String] = []
        if note.recordingFileName != nil { parts.append("has recording") }
        if note.enhancedMarkdown != nil { parts.append("has Dosa notes") }
        if generator.activeNoteId == note.id && generator.phase != .idle { parts.append("processing") }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.displayTitle)
                .appFont(size: 14)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(note.createdAt, style: .date)
                    .appFont(size: 12)
                if note.recordingFileName != nil {
                    Image(systemName: "waveform")
                        .font(.system(size: 12))
                }
                if note.enhancedMarkdown != nil {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                }
                if generator.activeNoteId == note.id && generator.phase != .idle {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .foregroundStyle(Theme.secondaryTextColor)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 1)
        .tag(note.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.displayTitle), \(note.createdAt.formatted(date: .abbreviated, time: .omitted))\(statusSummary)")
        .itemProvider {
            NSItemProvider(object: targetIds.map(\.uuidString).joined(separator: ",") as NSString)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.togglePin([note.id])
            } label: {
                Label(note.isPinned ? "Unpin" : "Pin",
                      systemImage: note.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onRequestDelete([note.id])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                store.togglePin(targetIds)
            } label: {
                let count = targetIds.count
                let base = targetsAllPinned ? "Unpin" : "Pin"
                Label(count > 1 ? "\(base) \(count) Notes" : "\(base) Note",
                      systemImage: targetsAllPinned ? "pin.slash" : "pin")
            }
            Menu {
                Button("No Folder") {
                    store.move(noteIds: targetIds, to: nil)
                }
                Divider()
                ForEach(store.flattenedFolders(), id: \.folder.id) { item in
                    Button(String(repeating: "    ", count: item.depth) + item.folder.name) {
                        store.move(noteIds: targetIds, to: item.folder.id)
                    }
                }
            } label: {
                Label(targetIds.count > 1 ? "Move \(targetIds.count) Notes to Folder" : "Move to Folder",
                      systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) {
                onRequestDelete(targetIds)
            } label: {
                Label(targetIds.count > 1 ? "Delete \(targetIds.count) Notes" : "Delete Note",
                      systemImage: "trash")
            }
        }
    }
}

private struct DeletedNoteRow: View {
    @EnvironmentObject private var store: NotesStore
    let note: Note
    @Binding var selectedNoteIds: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.displayTitle)
                .appFont(size: 14)
                .lineLimit(1)
                .foregroundStyle(Theme.secondaryTextColor)
            Text("\(store.daysRemaining(for: note)) days left")
                .appFont(size: 12)
                .foregroundStyle(Theme.tertiaryTextColor)
        }
        .padding(.vertical, 1)
        .tag(note.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.displayTitle), \(store.daysRemaining(for: note)) days left")
        .contextMenu {
            Button("Restore") {
                store.restore(note.id)
            }
            Button("Delete Permanently", role: .destructive) {
                selectedNoteIds.remove(note.id)
                store.deletePermanently(note.id)
            }
        }
    }
}
