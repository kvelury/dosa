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

    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Dosa", isDirectory: true)
    }

    private struct Snapshot: Codable {
        var notes: [Note] = []
        var folders: [Folder] = []
    }

    convenience init() {
        self.init(dataDirectory: Self.applicationSupportDirectory, recoverInterrupted: true)
    }

    init(dataDirectory: URL, recoverInterrupted: Bool) {
        let fm = FileManager.default
        self.dataDirectory = dataDirectory
        recordingsDirectory = dataDirectory.appendingPathComponent("Recordings", isDirectory: true)
        try? fm.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        load()
        purgeExpiredDeletedNotes()
        if recoverInterrupted {
            recoverInterruptedRecordings()
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.persistNow()
            }
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
    func createNote(in folderId: UUID? = nil, title: String = "", template: NoteTemplate? = nil) -> Note {
        var note = Note(title: title, folderId: folderId)
        if let template {
            note.title = title.isEmpty ? template.name : title
            note.manualText = template.body
            note.templateId = template.id
            note.templateName = template.name
            note.templateSeed = template.body
        }
        notes.insert(note, at: 0)
        scheduleSave()
        return note
    }

    func applyTemplate(_ template: NoteTemplate, to id: UUID) {
        guard var note = note(id: id) else { return }
        note.templateId = template.id
        note.templateName = template.name
        note.templateSeed = template.body
        let trimmed = note.manualText.trimmingCharacters(in: .whitespacesAndNewlines)
        note.manualText = trimmed.isEmpty ? template.body : note.manualText + "\n\n" + template.body
        update(note)
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
        note.calendarEventUID = nil
        note.calendarEventInstanceStart = nil
        note.calendarHTMLLink = nil
        note.calendarID = nil
        note.calendarEventSnapshot = nil
        update(note)
    }

    func activeNote(for identity: CalendarEventIdentity) -> Note? {
        CalendarNoteLinking.activeNote(
            in: notes,
            identity: identity,
            uid: \.calendarEventUID,
            instanceStart: \.calendarEventInstanceStart,
            isDeleted: \.isDeleted
        )
    }

    @discardableResult
    func openOrCreateNote(for event: CalendarEvent) -> Note {
        if let existing = activeNote(for: event.identity) {
            return existing
        }
        var note = Note(title: event.title)
        note.calendarEventUID = event.identity.iCalUID
        note.calendarEventInstanceStart = event.identity.instanceStart
        note.calendarHTMLLink = event.googleCalendarURL?.absoluteString
        note.calendarID = event.calendarID
        note.calendarEventSnapshot = event
        notes.insert(note, at: 0)
        scheduleSave()
        return note
    }

    /// Refreshes stored snapshots from the live calendar. Called as `calendar.events`
    /// changes so a note keeps the latest title/time after the meeting scrolls out
    /// of the sync window.
    func refreshCalendarSnapshots(from events: [CalendarEvent]) {
        var changed = false
        for index in notes.indices {
            guard let uid = notes[index].calendarEventUID,
                  let instanceStart = notes[index].calendarEventInstanceStart else { continue }
            guard let event = events.first(where: {
                $0.identity.matches(uid: uid, instanceStart: instanceStart)
            }) else { continue }
            if notes[index].calendarEventSnapshot != event {
                notes[index].calendarEventSnapshot = event
                changed = true
            }
        }
        if changed {
            scheduleSave()
        }
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
        removeRecordingFiles(for: note, includingHistory: true)
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

    /// The unmixed source tracks kept alongside a recording. Transcribing them
    /// separately is what lets on-device transcription tell the user's voice
    /// (mic) apart from everyone else's (system audio).
    enum RecordingTrack: String, CaseIterable {
        case mic = "-mic"
        case system = "-system"
    }

    func recordingURL(for note: Note) -> URL? {
        guard let fileName = note.recordingFileName else { return nil }
        return recordingsDirectory.appendingPathComponent(fileName)
    }

    /// A fresh, never-reused name for a new recording, e.g.
    /// `<noteId>-20260813-145830-417.m4a`.
    ///
    /// This is what makes overwriting structurally impossible rather than merely
    /// discouraged: because every recording gets its own path, no code path — a
    /// second Record click, a replace, a crash recovery — can ever write over
    /// audio that already exists. The note id prefix keeps a file traceable back
    /// to its note, which is how an interrupted capture is matched up at launch.
    func newRecordingFileName(for noteId: UUID) -> String {
        var name = "\(noteId.uuidString)-\(Self.stampFormatter.string(from: Date())).m4a"
        // Belt and braces: if a name somehow collides, take a different one rather
        // than returning a path that would overwrite an existing recording.
        while FileManager.default.fileExists(
            atPath: recordingsDirectory.appendingPathComponent(name).path
        ) {
            name = "\(noteId.uuidString)-\(UUID().uuidString).m4a"
        }
        return name
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// The note a recording file belongs to, read back from its name prefix.
    static func noteId(forRecordingNamed fileName: String) -> UUID? {
        UUID(uuidString: String(fileName.prefix(36)))
    }

    /// Side-track URL for a recording file name, e.g. `<id>-mic.m4a`.
    func trackURL(forRecordingNamed fileName: String, _ track: RecordingTrack) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        return recordingsDirectory.appendingPathComponent("\(base)\(track.rawValue).m4a")
    }

    /// Raw capture file written while a recording is in progress, e.g. `<id>-mic.caf`.
    /// These live here rather than the temp directory so an interrupted meeting is
    /// still on disk after a crash or relaunch, and can be recovered.
    func scratchURL(forRecordingNamed fileName: String, _ track: RecordingTrack) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        return recordingsDirectory.appendingPathComponent("\(base)\(track.rawValue).caf")
    }

    func recordingDestination(for noteId: UUID) -> AudioRecorder.Destination {
        let fileName = newRecordingFileName(for: noteId)
        return AudioRecorder.Destination(
            noteId: noteId,
            fileName: fileName,
            output: recordingsDirectory.appendingPathComponent(fileName),
            micTrack: trackURL(forRecordingNamed: fileName, .mic),
            systemTrack: trackURL(forRecordingNamed: fileName, .system),
            micScratch: scratchURL(forRecordingNamed: fileName, .mic),
            systemScratch: scratchURL(forRecordingNamed: fileName, .system)
        )
    }

    /// Side-track URL for a note, or nil when that track wasn't kept (older
    /// recordings made before per-track capture, or a failed export).
    func trackURL(for note: Note, _ track: RecordingTrack) -> URL? {
        guard let fileName = note.recordingFileName else { return nil }
        let url = trackURL(forRecordingNamed: fileName, track)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Deletes a note's recording files. Only ever called from the two paths where the
    /// user explicitly asked for it — Discard Recording, and permanently deleting a
    /// note — never as a side effect of recording.
    ///
    /// `includingHistory` sweeps every file keyed to the note, including earlier
    /// recordings the user replaced and interrupted captures that would otherwise be
    /// recovered onto a new note. That's right when the note itself is going away, but
    /// discarding one recording must not quietly take the older ones with it.
    private func removeRecordingFiles(for note: Note, includingHistory: Bool) {
        let fm = FileManager.default
        if let url = recordingURL(for: note) {
            try? fm.removeItem(at: url)
        }
        if let fileName = note.recordingFileName {
            for track in RecordingTrack.allCases {
                try? fm.removeItem(at: trackURL(forRecordingNamed: fileName, track))
                try? fm.removeItem(at: scratchURL(forRecordingNamed: fileName, track))
            }
        }
        guard includingHistory else { return }
        let prefix = note.id.uuidString
        let entries = (try? fm.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in entries where url.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: url)
        }
    }

    /// A recording that never reached `stop()` — the app quit or crashed mid-meeting,
    /// or the system audio stream died — leaves its raw capture files behind. Mix them
    /// into a real recording at launch so captured audio is never silently lost.
    ///
    /// When the note already has a recording, the salvaged audio lands on a new note
    /// instead of replacing it: recovery must never itself destroy a recording.
    private func recoverInterruptedRecordings() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []

        // Group leftover scratch files by the recording they were captured for.
        var pending: [String: [RecordingTrack: URL]] = [:]
        for url in entries where url.pathExtension == "caf" {
            let name = url.deletingPathExtension().lastPathComponent
            guard let track = RecordingTrack.allCases.first(where: { name.hasSuffix($0.rawValue) }) else { continue }
            pending[String(name.dropLast(track.rawValue.count)), default: [:]][track] = url
        }
        guard !pending.isEmpty else { return }

        Task { @MainActor [weak self] in
            for (base, scratch) in pending.sorted(by: { $0.key < $1.key }) {
                await self?.recover(base: base, scratch: scratch)
            }
        }
    }

    @MainActor
    private func recover(base: String, scratch: [RecordingTrack: URL]) async {
        let origin = Self.noteId(forRecordingNamed: base).flatMap { note(id: $0) }
        // Land on the original note only when doing so takes nothing away. If it
        // already has a recording, the salvage gets its own note — recovery must
        // never be the thing that destroys a recording.
        let target: Note
        if let origin, origin.recordingFileName == nil, !origin.isDeleted {
            target = origin
        } else {
            target = createNote(
                in: origin?.folderId,
                title: origin.map { "\($0.displayTitle) (Recovered)" } ?? "Recovered Recording"
            )
        }

        let fileName = newRecordingFileName(for: target.id)
        let inputs = RecordingTrack.allCases.compactMap { scratch[$0] }
        guard let duration = try? await AudioRecorder.mix(
            inputs: inputs,
            to: recordingsDirectory.appendingPathComponent(fileName)
        ) else { return }

        for track in RecordingTrack.allCases {
            guard let url = scratch[track] else { continue }
            _ = try? await AudioRecorder.mix(inputs: [url], to: trackURL(forRecordingNamed: fileName, track))
        }

        setRecording(noteId: target.id, fileName: fileName, duration: duration)
        for url in inputs {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Attaches an existing audio or video file to a note, transcoding it to the `.m4a`
    /// the rest of the app expects. The file lands under a fresh name like any other
    /// recording, so importing can no more overwrite existing audio than recording can.
    @MainActor
    func importRecording(from sourceURL: URL, into noteId: UUID) async throws {
        guard note(id: noteId) != nil else { return }
        let fileName = newRecordingFileName(for: noteId)
        let duration: TimeInterval
        do {
            // `mix` keeps only the audio track, so this doubles as the extractor for
            // video containers, with its staging-file and duration checks intact.
            duration = try await AudioRecorder.mix(
                inputs: [sourceURL],
                to: recordingsDirectory.appendingPathComponent(fileName),
                durationCheck: .lenient
            )
        } catch {
            throw ImportError.noAudioTrack(
                sourceURL.lastPathComponent,
                detail: error.localizedDescription
            )
        }

        setRecording(noteId: noteId, fileName: fileName, duration: duration)
        // An untitled note takes the file's name — usually the best title available.
        if var note = note(id: noteId), note.title.trimmingCharacters(in: .whitespaces).isEmpty {
            note.title = sourceURL.deletingPathExtension().lastPathComponent
            update(note)
        }
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
        removeRecordingFiles(for: note, includingHistory: false)
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
