import SwiftUI
import AppKit

struct MenuBarMenu: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var generator: GenerationManager
    @EnvironmentObject private var notifier: NotificationManager
    @EnvironmentObject private var updater: UpdateManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Note") {
            newNote()
        }
        if recorder.isRecording {
            Button("Stop Recording") {
                RecordingCommand.stop(
                    recorder: recorder,
                    store: store,
                    generator: generator,
                    notifier: notifier
                )
            }
        } else {
            Button("Start Recording in New Note") {
                RecordingCommand.startInNewNote(
                    store: store,
                    appState: appState,
                    openWindow: openWindow
                )
            }
        }
        Button("Import Audio/Video into New Note…") {
            importIntoNewNote()
        }
        Divider()
        Button("Settings…") {
            openSettings()
        }
        Button("Check for Updates…") {
            checkForUpdates()
        }
        Divider()
        Button("Quit Dosa") {
            QuitGuard.requestQuit(
                recorder: recorder,
                generator: generator,
                appState: appState
            )
        }
    }

    private func newNote() {
        let note = store.createNote()
        appState.selectedNoteIds = [note.id]
        showMainWindow()
    }

    private func importIntoNewNote() {
        NSApp.activate()
        guard let url = RecordingImporter.pickFile(for: .newNote) else { return }
        let note = store.createNote()
        appState.pendingNoteAction = PendingNoteAction(noteId: note.id, kind: .importFile(url))
        appState.selectedNoteIds = [note.id]
        showMainWindow()
    }

    private func openSettings() {
        appState.showSettings = true
        showMainWindow()
    }

    private func checkForUpdates() {
        openSettings()
        updater.check()
    }

    /// Brings the main window forward, creating it if the user has closed it.
    /// A Window scene is single-instance, so this never opens a duplicate.
    private func showMainWindow() {
        NSApp.activate()
        openWindow(id: DosaApp.mainWindowID)
    }
}
