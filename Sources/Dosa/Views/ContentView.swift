import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recorder: AudioRecorder
    @State private var showSettings = false
    @State private var interruptionMessage: String?
    @AppStorage(AppSettings.themeKey) private var themeName = "Classic"
    @AppStorage(AppSettings.accentOverrideKey) private var accentOverride = "Theme Default"

    /// Bridges the multi-select sidebar to views that work with a single note.
    private var singleSelectionBinding: Binding<UUID?> {
        Binding(
            get: { appState.singleSelectedNoteId },
            set: { newValue in
                appState.selectedNoteIds = newValue.map { [$0] } ?? []
            }
        )
    }

    /// True exactly when the detail pane is showing something other than Welcome.
    /// Mirrors `body`'s branches rather than testing `selectedNoteIds` directly: a
    /// selected id whose note no longer resolves falls through to Welcome, and a
    /// back arrow floating over the home screen is the one wrong state possible here.
    private var isShowingDetail: Bool {
        if let id = appState.singleSelectedNoteId { return store.note(id: id) != nil }
        return appState.selectedNoteIds.count > 1
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedNoteIds: $appState.selectedNoteIds, showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 380)
        } detail: {
            Group {
                if let id = appState.singleSelectedNoteId, let note = store.note(id: id) {
                    if note.isDeleted {
                        DeletedNoteView(noteId: id, selectedNoteId: singleSelectionBinding)
                            .id(id)
                    } else {
                        NoteEditorView(noteId: id, selectedNoteId: singleSelectionBinding)
                            .id(id)
                    }
                } else if appState.selectedNoteIds.count > 1 {
                    MultiSelectionView(count: appState.selectedNoteIds.count)
                } else {
                    WelcomeView()
                }
            }
            .id(appState.themeRefreshTick)
            .modifier(SetupBannerInset(onOpenSettings: { showSettings = true }))
            // Hides the toolbar's material/separator, not the toolbar itself, so
            // the theme fill below paints edge-to-edge under that region while
            // the toolbar keeps its items. See §9b of the design doc.
            .backToWelcomeToolbar(isVisible: isShowingDetail, tint: Theme.current.accentColor) {
                appState.selectedNoteIds = []
            }
            .toolbarBackground(.hidden, for: .windowToolbar)
            .background(Theme.current.editorBackgroundColor.ignoresSafeArea(edges: .top))
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $appState.showGlobalSearch) {
            GlobalSearchView(selectedNoteId: singleSelectionBinding)
        }
        .sheet(isPresented: Binding(
            get: { interruptionMessage != nil },
            set: { if !$0 { interruptionMessage = nil } }
        )) {
            ErrorDialogView(message: interruptionMessage ?? "", detail: nil)
        }
        // A capture that dies on its own still hands back whatever it recorded;
        // save it to the note and select it so the audio is never stranded.
        .onChange(of: recorder.interruption) { _, interruption in
            guard let interruption else { return }
            recorder.interruption = nil
            if let recovered = interruption.recovered {
                store.setRecording(
                    noteId: recovered.noteId,
                    fileName: recovered.fileName,
                    duration: recovered.duration
                )
                appState.selectedNoteIds = [recovered.noteId]
            }
            interruptionMessage = interruption.message
        }
        .onAppear {
            AppSettings.applyAppearance()
        }
        .tint(Theme.current.accentColor)
    }
}
