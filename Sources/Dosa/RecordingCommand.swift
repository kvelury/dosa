import SwiftUI
import AppKit

@MainActor
enum RecordingCommand {
    /// Whether ⌘R (and the File menu item) do anything right now. Drives `.disabled`.
    static func isAvailable(store: NotesStore, appState: AppState, recorder: AudioRecorder) -> Bool {
        if recorder.isRecording { return true }
        guard let id = appState.singleSelectedNoteId,
              let note = store.note(id: id),
              !note.isDeleted
        else { return true }
        return note.existingWorkDescription == nil
    }

    /// The ⌘R action: stop if recording, otherwise start where it is safe to.
    static func toggle(
        store: NotesStore,
        appState: AppState,
        recorder: AudioRecorder,
        notifier: NotificationManager,
        openWindow: OpenWindowAction
    ) {
        if recorder.isRecording {
            stop(recorder: recorder, store: store, notifier: notifier)
            return
        }
        start(store: store, appState: appState, openWindow: openWindow)
    }

    /// Ends the capture wherever it started, saves it to its own note, and toasts.
    /// Callable with no editor mounted — this is what makes "stop from anywhere" work.
    ///
    /// `onError` is for the in-editor Stop button, which still owns the error sheet.
    /// ⌘R and the menu bar omit it and toast instead.
    static func stop(
        recorder: AudioRecorder,
        store: NotesStore,
        notifier: NotificationManager,
        onError: ((Error) -> Void)? = nil
    ) {
        Task {
            do {
                let recording = try await recorder.stop()
                store.setRecording(
                    noteId: recording.noteId,
                    fileName: recording.fileName,
                    duration: recording.duration
                )
                let title = store.note(id: recording.noteId)?.displayTitle ?? "Untitled Note"
                notifier.post(.recordingSaved(noteId: recording.noteId, title: title))
            } catch {
                if let onError {
                    onError(error)
                } else {
                    notifier.showToast(error.localizedDescription)
                }
            }
        }
    }

    /// Always a fresh note — the menu bar's existing semantics, unchanged.
    static func startInNewNote(
        store: NotesStore,
        appState: AppState,
        openWindow: OpenWindowAction
    ) {
        let note = store.createNote()
        appState.pendingNoteAction = PendingNoteAction(noteId: note.id, kind: .record)
        appState.selectedNoteIds = [note.id]
        NSApp.activate()
        openWindow(id: DosaApp.mainWindowID)
    }

    /// Starts in the open note when that is safe, otherwise in a fresh note.
    private static func start(
        store: NotesStore,
        appState: AppState,
        openWindow: OpenWindowAction
    ) {
        if let id = appState.singleSelectedNoteId,
           let note = store.note(id: id),
           !note.isDeleted {
            if note.existingWorkDescription != nil { return }
            appState.pendingNoteAction = PendingNoteAction(noteId: note.id, kind: .record)
        } else {
            let note = store.createNote()
            appState.pendingNoteAction = PendingNoteAction(noteId: note.id, kind: .record)
            appState.selectedNoteIds = [note.id]
        }
        NSApp.activate()
        openWindow(id: DosaApp.mainWindowID)
    }
}

/// File-menu New / Record / Import. Lives here so `@Environment(\.openWindow)` is
/// reachable — it is not available on the `App` struct itself.
struct RecordingCommands: Commands {
    @ObservedObject var store: NotesStore
    @ObservedObject var appState: AppState
    @ObservedObject var recorder: AudioRecorder
    @ObservedObject var notifier: NotificationManager
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") {
                let note = store.createNote()
                appState.selectedNoteIds = [note.id]
            }
            .keyboardShortcut("n", modifiers: .command)
            Button(recorder.isRecording ? "Stop Recording" : "Start Recording") {
                RecordingCommand.toggle(
                    store: store,
                    appState: appState,
                    recorder: recorder,
                    notifier: notifier,
                    openWindow: openWindow
                )
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!RecordingCommand.isAvailable(store: store, appState: appState, recorder: recorder))
            Button("Import Audio or Video…") {
                guard let url = RecordingImporter.pickFile(for: .newNote) else { return }
                let note = store.createNote()
                appState.pendingNoteAction = PendingNoteAction(noteId: note.id, kind: .importFile(url))
                appState.selectedNoteIds = [note.id]
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}
