import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var appState: AppState
    @State private var showSettings = false
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

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedNoteIds: $appState.selectedNoteIds, showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 380)
        } detail: {
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
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $appState.showGlobalSearch) {
            GlobalSearchView(selectedNoteId: singleSelectionBinding)
        }
        .onAppear {
            AppSettings.applyAppearance()
        }
        .tint(Theme.current.accentColor)
    }
}
