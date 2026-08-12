import Foundation
import SwiftUI
import AppKit

struct FolderListItem {
    let folder: Folder
    let depth: Int
}

final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var folders: [Folder] = []

    static let trashRetentionDays = 30

    let dataDirectory: URL
    let recordingsDirectory: URL
    private var storeURL: URL { dataDirectory.appendingPathComponent("store.json") }
    private var saveTask: Task<Void, Never>?

    private struct Snapshot: Codable {
        var notes: [Note] = []
        var folders: [Folder] = []
    }

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDirectory = appSupport.appendingPathComponent("Dosa", isDirectory: true)
        recordingsDirectory = dataDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? fm.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        load()
        purgeExpiredDeletedNotes()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.persistNow()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            notes = snapshot.notes
            folders = snapshot.folders
        }
    }

    private func persistNow() {
        saveTask?.cancel()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Snapshot(notes: notes, folders: folders)) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    // MARK: - Notes

    func note(id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    func noteBinding(id: UUID) -> Binding<Note>? {
        guard note(id: id) != nil else { return nil }
        return Binding(
            get: { [weak self] in self?.note(id: id) ?? Note() },
            set: { [weak self] newValue in self?.update(newValue) }
        )
    }

    @discardableResult
    func createNote(in folderId: UUID? = nil) -> Note {
        let note = Note(folderId: folderId)
        notes.insert(note, at: 0)
        scheduleSave()
        return note
    }

    func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
        scheduleSave()
    }

    func move(noteId: UUID, to folderId: UUID?) {
        guard var note = note(id: noteId) else { return }
        note.folderId = folderId
        update(note)
    }

    func move(noteIds: Set<UUID>, to folderId: UUID?) {
        for id in noteIds {
            move(noteId: id, to: folderId)
        }
    }

    /// Pins every note in `ids` if any of them is unpinned; otherwise unpins them all.
    func togglePin(_ ids: Set<UUID>) {
        let shouldPin = ids.contains { note(id: $0)?.isPinned == false }
        for id in ids {
            guard var note = note(id: id) else { continue }
            note.pinnedAt = shouldPin ? Date() : nil
            if let index = notes.firstIndex(where: { $0.id == id }) {
                notes[index] = note
            }
        }
        scheduleSave()
    }

    func moveToTrash(_ id: UUID) {
        guard var note = note(id: id) else { return }
        note.deletedAt = Date()
        update(note)
    }

    func restore(_ id: UUID) {
        guard var note = note(id: id) else { return }
        note.deletedAt = nil
        if let folderId = note.folderId, folders.first(where: { $0.id == folderId }) == nil {
            note.folderId = nil
        }
        update(note)
    }

    func deletePermanently(_ id: UUID) {
        guard let note = note(id: id) else { return }
        if let url = recordingURL(for: note) {
            try? FileManager.default.removeItem(at: url)
        }
        notes.removeAll { $0.id == id }
        scheduleSave()
    }

    func emptyTrash() {
        for note in deletedNotes {
            deletePermanently(note.id)
        }
    }

    func purgeExpiredDeletedNotes() {
        let cutoff = Date().addingTimeInterval(-TimeInterval(Self.trashRetentionDays) * 24 * 3600)
        for note in notes where note.deletedAt.map({ $0 < cutoff }) == true {
            deletePermanently(note.id)
        }
    }

    func daysRemaining(for note: Note) -> Int {
        guard let deletedAt = note.deletedAt else { return Self.trashRetentionDays }
        let elapsed = Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
        return max(0, Self.trashRetentionDays - elapsed)
    }

    // MARK: - Recordings

    func recordingURL(for note: Note) -> URL? {
        guard let fileName = note.recordingFileName else { return nil }
        return recordingsDirectory.appendingPathComponent(fileName)
    }

    func setRecording(noteId: UUID, fileName: String, duration: TimeInterval) {
        guard var note = note(id: noteId) else { return }
        note.recordingFileName = fileName
        note.recordingDuration = duration
        note.transcript = nil
        update(note)
    }

    func setNotionPage(noteId: UUID, pageId: String?, pageURL: String?) {
        guard var note = note(id: noteId) else { return }
        note.notionPageId = pageId
        note.notionPageURL = pageURL
        update(note)
    }

    func discardRecording(_ id: UUID) {
        guard var note = note(id: id) else { return }
        if let url = recordingURL(for: note) {
            try? FileManager.default.removeItem(at: url)
        }
        note.recordingFileName = nil
        note.recordingDuration = nil
        note.transcript = nil
        update(note)
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(name: String, parentId: UUID?) -> Folder {
        let folder = Folder(name: name, parentId: parentId)
        folders.append(folder)
        scheduleSave()
        return folder
    }

    func deleteFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        for index in notes.indices where notes[index].folderId == id {
            notes[index].folderId = folder.parentId
        }
        for index in folders.indices where folders[index].parentId == id {
            folders[index].parentId = folder.parentId
        }
        folders.removeAll { $0.id == id }
        scheduleSave()
    }

    func subfolders(of parentId: UUID?) -> [Folder] {
        folders
            .filter { $0.parentId == parentId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func flattenedFolders() -> [FolderListItem] {
        var result: [FolderListItem] = []
        func walk(parentId: UUID?, depth: Int) {
            for folder in subfolders(of: parentId) {
                result.append(FolderListItem(folder: folder, depth: depth))
                walk(parentId: folder.id, depth: depth + 1)
            }
        }
        walk(parentId: nil, depth: 0)
        return result
    }

    // MARK: - Queries & stats

    var activeNotes: [Note] {
        notes.filter { !$0.isDeleted }
    }

    var deletedNotes: [Note] {
        notes
            .filter(\.isDeleted)
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Pinned notes live in their own section, so folder/root listings exclude them.
    func notes(in folderId: UUID?) -> [Note] {
        activeNotes
            .filter { $0.folderId == folderId && !$0.isPinned }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var pinnedNotes: [Note] {
        activeNotes
            .filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantPast) > ($1.pinnedAt ?? .distantPast) }
    }

    var meetingsRecorded: Int {
        activeNotes.filter { $0.recordingFileName != nil || $0.transcript != nil }.count
    }

    var totalRecordedTimeText: String {
        let total = activeNotes.compactMap(\.recordingDuration).reduce(0, +)
        return total > 0 ? TimeFormatting.spoken(total) : "0m"
    }

    var notesGeneratedCount: Int {
        activeNotes.filter { $0.enhancedMarkdown != nil }.count
    }
}
