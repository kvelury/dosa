import SwiftUI
import AppKit

/// A note plus the audio it should acquire once its editor is on screen — either by
/// recording, or by importing a file the user already picked.
struct PendingNoteAction: Equatable {
    enum Kind: Equatable {
        case record
        case importFile(URL)
    }

    let noteId: UUID
    let kind: Kind
}

extension PendingNoteAction.Kind {
    var isImport: Bool {
        if case .importFile = self { return true }
        return false
    }

    var newNoteButtonTitle: String {
        isImport ? "Import into a New Note" : "Record in a New Note"
    }

    var newNoteExplanation: String {
        isImport
            ? "Importing into a new note keeps this one exactly as it is."
            : "Recording in a new note keeps this one exactly as it is."
    }
}

/// Window-level UI state shared between views and the menu-bar commands.
final class AppState: ObservableObject {
    @Published var selectedNoteIds: Set<UUID> = []

    /// The note shown in the detail pane — only when exactly one is selected.
    var singleSelectedNoteId: UUID? {
        selectedNoteIds.count == 1 ? selectedNoteIds.first : nil
    }
    @Published var showGlobalSearch = false
    /// Lives here rather than in ContentView so the ⌘, menu command can open
    /// Settings too — same reason as showGlobalSearch above.
    @Published var showSettings = false
    /// Bumped to a fresh UUID each time Cmd+F fires; the open note editor consumes it.
    @Published var noteSearchRequest: UUID?
    /// Work that should begin as soon as a note's editor appears. The editor is rebuilt
    /// on selection change, so a request made while creating the note has to outlive it.
    @Published var pendingNoteAction: PendingNoteAction?
    /// Notes whose audio import is still transcoding. On AppState rather than the
    /// editor because the import Task outlives the view — and because quitting has
    /// to know about it.
    @Published var importingNoteIds: Set<UUID> = []
    /// Bumped when Settings closes; ContentView uses it to rebuild the view tree
    /// so theme changes apply everywhere at once.
    @Published var themeRefreshTick = 0
}

public struct DosaApp: App {
    static let mainWindowID = "main"

    @StateObject private var store = NotesStore()
    @StateObject private var templates = TemplateStore.shared
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var live = LiveTranscriber()
    @StateObject private var player = AudioPlayer()
    @StateObject private var generator = GenerationManager()
    @StateObject private var search = SearchCoordinator()
    @StateObject private var appState = AppState()
    @StateObject private var notion = NotionManager()
    @StateObject private var calendar = GoogleCalendarManager()
    @StateObject private var notifier = NotificationManager()
    @StateObject private var updater = UpdateManager()

    public init() {}

    /// One Format-menu row. Disabled unless a note editor has focus, so the
    /// shortcut can't fire into a text field or the note list.
    private func formatItem(
        _ action: MarkdownFormattingAction,
        _ key: KeyEquivalent,
        _ modifiers: EventModifiers
    ) -> some View {
        Button(action.title) {
            MarkdownFormattingCommand.perform(action)
        }
        .keyboardShortcut(key, modifiers: modifiers)
        .disabled(!MarkdownFormattingCommand.canFormat)
    }

    public var body: some Scene {
        Window("Dosa", id: Self.mainWindowID) {
            ContentView()
                .environmentObject(store)
                .environmentObject(templates)
                .environmentObject(recorder)
                .environmentObject(live)
                .environmentObject(player)
                .environmentObject(generator)
                .environmentObject(search)
                .environmentObject(appState)
                .environmentObject(notion)
                .environmentObject(calendar)
                .environmentObject(notifier)
                .environmentObject(updater)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            RecordingCommands(
                store: store,
                appState: appState,
                recorder: recorder,
                live: live,
                generator: generator,
                notifier: notifier
            )
            // Settings is a sheet, not a Settings scene, so the standard app-menu
            // slot has to be filled by hand — otherwise ⌘, is dead.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appState.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appState.showSettings = true
                    updater.check()
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Dosa") {
                    QuitGuard.requestQuit(
                        recorder: recorder,
                        generator: generator,
                        appState: appState
                    )
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Note") {
                    appState.selectedNoteIds = []
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Format") {
                formatItem(.bold, "b", [.command])
                formatItem(.italic, "i", [.command])
                formatItem(.strikethrough, "x", [.command, .shift])
                formatItem(.inlineCode, "e", [.command])
                Divider()
                formatItem(.heading(1), "1", [.command, .option])
                formatItem(.heading(2), "2", [.command, .option])
                formatItem(.heading(3), "3", [.command, .option])
                Divider()
                formatItem(.bulletList, "8", [.command, .shift])
                formatItem(.numberedList, "7", [.command, .shift])
                formatItem(.taskList, "9", [.command, .shift])
                formatItem(.blockquote, ".", [.command, .shift])
                Divider()
                formatItem(.indent, "]", [.command])
                formatItem(.outdent, "[", [.command])
                // ⌘K is Search All Notes, so Link takes the control variant.
                formatItem(.link, "k", [.command, .control])
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

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(store)
                .environmentObject(templates)
                .environmentObject(appState)
                .environmentObject(recorder)
                .environmentObject(live)
                .environmentObject(generator)
                .environmentObject(notifier)
                .environmentObject(updater)
        } label: {
            Image(nsImage: MenuBarIcon.current(
                recording: recorder.isRecording,
                phase: recorder.ringPhase
            ))
            .accessibilityLabel(recorder.isRecording ? "Dosa, recording" : "Dosa")
        }
        .menuBarExtraStyle(.menu)
    }
}
