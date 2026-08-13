import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var appState: AppState
    @Binding var selectedNoteIds: Set<UUID>
    @Binding var showSettings: Bool

    @State private var newFolderParentId: UUID?
    @State private var newFolderName = ""
    @State private var showNewFolderAlert = false
    @State private var confirmEmptyTrash = false
    @State private var pendingDeleteIds: Set<UUID> = []
    @State private var deletedNotesExpanded = false

    @AppStorage(AppSettings.llmProviderKey) private var llmProvider = "Gemini"
    @AppStorage(AppSettings.modelKey) private var geminiModel = AppSettings.defaultModel
    @AppStorage(AppSettings.deepseekModelKey) private var deepseekModel = AppSettings.defaultDeepSeekModel

    /// The model the default provider will actually use, for the footer line.
    private var activeModelName: String {
        if AppSettings.supportedProviders.contains(llmProvider), llmProvider == "DeepSeek" {
            return AppSettings.resolveDeepSeekModel(deepseekModel)
        }
        return AppSettings.resolveModel(geminiModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    promptNewFolder(nil)
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("New folder")
                Button {
                    appState.showGlobalSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search all notes and transcripts (⌘K)")
                Spacer()
                Button {
                    let note = store.createNote()
                    selectedNoteIds = [note.id]
                } label: {
                    Image(systemName: "plus")
                }
                .help("New note (⌘N)")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 34)
            .padding(.bottom, 8)

            notesList

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Button {
                    showSettings = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 16, weight: .medium))
                        Text("Settings")
                            .font(.system(size: 14))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .help("LLM provider API key, prompts, and app options")
                (Text("v\(Self.appVersion)")
                    + Text("  ·  ")
                    + Text(activeModelName).italic())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 10)
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

    private static let appVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    private var notesList: some View {
        List(selection: $selectedNoteIds) {
            if !store.pinnedNotes.isEmpty {
                Section("Pinned") {
                    ForEach(store.pinnedNotes) { note in
                        NoteRow(
                            note: note,
                            selectedNoteIds: $selectedNoteIds,
                            onRequestDelete: requestDelete
                        )
                    }
                }
            }

            Section {
                ForEach(store.subfolders(of: nil)) { folder in
                    FolderRow(
                        folder: folder,
                        selectedNoteIds: $selectedNoteIds,
                        onNewFolder: promptNewFolder,
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
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            confirmEmptyTrash = true
                        } label: {
                            Label("Empty Deleted Notes…", systemImage: "trash.slash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    Label("Deleted Notes", systemImage: "trash")
                        .font(.system(size: 14))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            deletedNotesExpanded.toggle()
                        }
                }
            } footer: {
                if !store.deletedNotes.isEmpty {
                    Text("Deleted notes are removed permanently after \(NotesStore.trashRetentionDays) days.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        .background(SidebarDeselectCatcher { selectedNoteIds = [] })
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
                    .foregroundStyle(Color.accentColor)
            }
            Spacer()
        }
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
            Label(folder.name, systemImage: "folder")
                .font(.system(size: 14))
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.25) : Color.clear)
                )
                .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    isExpanded.toggle()
                }
                .contextMenu {
                    Button("New Note in \"\(folder.name)\"") {
                        let note = store.createNote(in: folder.id)
                        selectedNoteIds = [note.id]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.displayTitle)
                .font(.system(size: 14))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(note.createdAt, style: .date)
                    .font(.system(size: 12))
                if note.recordingFileName != nil {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                }
                if note.enhancedMarkdown != nil {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                }
                if generator.activeNoteId == note.id && generator.phase != .idle {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
        .tag(note.id)
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
                .font(.system(size: 14))
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Text("\(store.daysRemaining(for: note)) days left")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .tag(note.id)
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
