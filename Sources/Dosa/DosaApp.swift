import SwiftUI
import AppKit

/// Window-level UI state shared between views and the menu-bar commands.
final class AppState: ObservableObject {
    @Published var selectedNoteIds: Set<UUID> = []

    /// The note shown in the detail pane — only when exactly one is selected.
    var singleSelectedNoteId: UUID? {
        selectedNoteIds.count == 1 ? selectedNoteIds.first : nil
    }
    @Published var showGlobalSearch = false
    /// Bumped to a fresh UUID each time Cmd+F fires; the open note editor consumes it.
    @Published var noteSearchRequest: UUID?
    /// Set when recording should start as soon as this note's editor appears — the
    /// editor is rebuilt on selection change, so the request has to outlive it.
    @Published var pendingRecordNoteId: UUID?
    /// Bumped when Settings closes; ContentView uses it to rebuild the view tree
    /// so theme changes apply everywhere at once.
    @Published var themeRefreshTick = 0
}

@main
struct DosaApp: App {
    @StateObject private var store = NotesStore()
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var player = AudioPlayer()
    @StateObject private var generator = GenerationManager()
    @StateObject private var search = SearchCoordinator()
    @StateObject private var appState = AppState()
    @StateObject private var notion = NotionManager()

    var body: some Scene {
        WindowGroup("Dosa") {
            ContentView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(player)
                .environmentObject(generator)
                .environmentObject(search)
                .environmentObject(appState)
                .environmentObject(notion)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    let note = store.createNote()
                    appState.selectedNoteIds = [note.id]
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Note") {
                    appState.selectedNoteIds = []
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Search") {
                Button("Search All Notes…") {
                    appState.showGlobalSearch = true
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Find in Note…") {
                    appState.noteSearchRequest = UUID()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
