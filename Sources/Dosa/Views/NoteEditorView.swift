import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NoteEditorView: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var templates: TemplateStore
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var generator: GenerationManager
    @EnvironmentObject private var search: SearchCoordinator
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var notion: NotionManager
    @EnvironmentObject private var notifier: NotificationManager
    @EnvironmentObject private var calendar: GoogleCalendarManager

    let noteId: UUID
    @Binding var selectedNoteId: UUID?

    enum ViewMode: String, CaseIterable {
        case myNotes = "My Notes"
        case aiNotes = "Dosa Notes"
    }

    @State private var viewMode: ViewMode = .myNotes
    @State private var showTranscript = false
    @State private var confirmDelete = false
    @State private var confirmDiscardRecording = false
    /// The action waiting on the user's answer to the "already has content" prompt.
    @State private var pendingReplacement: PendingNoteAction.Kind?
    @State private var isDropTargeted = false
    @State private var localError: String?
    @State private var localErrorDetail: String?
    @State private var showNoteSearch = false
    @State private var showQuickSettings = false
    /// Measured height of the bar's top box — the pull-tab, plus the panel when
    /// it is open. Seeded at the collapsed height so frame one is already right.
    @State private var topBoxHeight: CGFloat = NoteEditorView.tabHeight
    @AppStorage(AppSettings.dosaColorKey) private var dosaColorName = "Theme Default"
    @AppStorage(AppSettings.themeKey) private var themeName = "Classic"
    @AppStorage(AppSettings.accentOverrideKey) private var accentOverride = "Theme Default"
    @State private var editorHighlight: TextHighlight?
    @State private var transcriptHighlight: TextHighlight?
    @State private var showDatePicker = false
    @State private var showMeeting = false

    private var isImporting: Bool {
        appState.importingNoteIds.contains(noteId)
    }

    var body: some View {
        if let noteBinding = store.noteBinding(id: noteId) {
            editor(note: noteBinding)
        } else {
            HomeView()
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func editor(note: Binding<Note>) -> some View {
        let current = note.wrappedValue
        VStack(alignment: .leading, spacing: 0) {
            header(note: note, current: current)
            Divider()
            content(note: note, current: current)
        }
        .background(Theme.current.editorBackgroundColor)
        .onAppear {
            if current.enhancedMarkdown != nil {
                viewMode = .aiNotes
            }
            handleReveal(search.pendingReveal)
            consumePendingAction()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
        .onChange(of: search.pendingReveal) { _, newValue in
            handleReveal(newValue)
        }
        .onChange(of: appState.noteSearchRequest) { _, request in
            guard request != nil else { return }
            appState.noteSearchRequest = nil
            if current.transcript != nil || current.enhancedMarkdown != nil {
                showNoteSearch = true
            }
        }
        .onChange(of: appState.pendingNoteAction) { _, _ in consumePendingAction() }
        // Automatic mode can finish while the user sits in the note. `onAppear`
        // only covers opening it afterwards, so without this the notes land
        // behind the My Notes tab with no sign anything happened.
        .onChange(of: current.enhancedMarkdown) { _, markdown in
            if markdown != nil { viewMode = .aiNotes }
        }
        .overlay(alignment: .bottom) {
            floatingBar(current: current)
        }
        .trailingToolbarItem {
            actionsMenu(current: current)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.current.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptView(note: current, highlight: transcriptHighlight)
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete) {
            Button("Yes, Delete", role: .destructive) {
                player.stop()
                store.moveToTrash(noteId)
                selectedNoteId = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The note, its transcript, and its recording move to Deleted Notes, and are permanently removed after \(NotesStore.trashRetentionDays) days.")
        }
        .confirmationDialog(
            "This note already has \(current.existingWorkDescription ?? "content")",
            isPresented: Binding(
                get: { pendingReplacement != nil },
                set: { if !$0 { pendingReplacement = nil } }
            )
        ) {
            let kind = pendingReplacement ?? .record
            Button(kind.newNoteButtonTitle) { startInNewNote(kind) }
            Button("Replace It", role: .destructive) { begin(kind) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(replaceWarning(current, kind: pendingReplacement ?? .record)) \(pendingReplacement?.newNoteExplanation ?? "")")
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscardRecording) {
            Button("Discard Recording", role: .destructive) {
                player.stop()
                store.discardRecording(noteId)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The audio recording and its transcript will be removed so you can record again. Your notes stay.")
        }
        .sheet(isPresented: errorPresented) {
            ErrorDialogView(
                message: localError ?? generator.errorMessage ?? "An unknown error occurred.",
                detail: localError != nil ? localErrorDetail : generator.errorDetail
            )
        }
    }

    private func header(note: Binding<Note>, current: Note) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Untitled Note", text: note.title)
                .textFieldStyle(.plain)
                .appFont(.noteTitle)
            HStack(spacing: 8) {
                EditorPill(action: { showDatePicker = true }) {
                    Text(current.createdAt.formatted(date: .long, time: .omitted))
                }
                .popover(isPresented: $showDatePicker) {
                    ScaledDatePicker(selection: note.createdAt)
                        .padding(12)
                }
                if let event = meeting(for: current) {
                    EditorPill(action: { showMeeting = true }) {
                        Image(systemName: "calendar")
                    }
                    .help(event.displayTitle)
                    .accessibilityLabel(event.displayTitle)
                    .popover(isPresented: $showMeeting) {
                        CalendarEventDetailView(event: event, style: .compact)
                    }
                }
                if let duration = current.recordingDuration {
                    EditorPill {
                        Label(TimeFormatting.clock(duration), systemImage: "waveform")
                    }
                }
                if current.enhancedMarkdown != nil {
                    EditorPill(info: generationInfo(for: current)) {
                        Image(systemName: "sparkles")
                    }
                    .accessibilityLabel("Notes generation details")
                    .accessibilityValue(generationInfo(for: current) ?? "")
                }
                Spacer()
                if current.enhancedMarkdown != nil {
                    Picker("", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Note view")
                    .frame(width: 210)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .zIndex(1)
    }

    /// Resolves the meeting a note is linked to: the live calendar first, so an
    /// event still inside the sync window always shows current data, falling
    /// back to the stored snapshot and finally a minimal placeholder for notes
    /// created before snapshots existed.
    private func meeting(for note: Note) -> CalendarEvent? {
        guard let uid = note.calendarEventUID,
              let start = note.calendarEventInstanceStart else { return nil }
        let identity = CalendarEventIdentity(iCalUID: uid, instanceStart: start)
        return calendar.events.first { $0.identity == identity }
            ?? note.calendarEventSnapshot
            ?? .placeholder(for: note)
    }

    /// "deepseek-v4-flash (detailed)" for the sparkle pill's hover card. Nil on
    /// notes generated before the model and style were recorded — the pill still
    /// shows, it just has nothing to explain.
    private func generationInfo(for note: Note) -> String? {
        guard let model = note.generationModel, let style = note.generationStyle else { return nil }
        return "\(model.lowercased()) (\(style.lowercased()))"
    }

    @ViewBuilder
    private func content(note: Binding<Note>, current: Note) -> some View {
        if viewMode == .aiNotes, current.enhancedMarkdown != nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Label("Your notes", systemImage: "circle.fill")
                        .appFont(size: 13)
                        .foregroundStyle(.primary)
                    Label("Dosa additions", systemImage: "circle.fill")
                        .appFont(size: 13)
                        .foregroundStyle(DiffEngine.aiColor)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 7)
                .padding(.bottom, 7)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Legend: your notes shown in the default color, Dosa's additions tinted")
                MarkdownTextEditor(
                    text: enhancedBinding(note: note),
                    diffAgainst: current.manualText,
                    highlight: editorHighlight,
                    bottomContentInset: Self.barBottomInset,
                    onMediaFileDrop: { requestAudio(.importFile($0)) },
                    onMediaDragChanged: { isDropTargeted = $0 }
                )
                .accessibilityLabel("Dosa notes, editable")
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if current.enhancedMarkdown != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "lock")
                            .font(.caption)
                        Text("Read-only — Dosa has generated notes from these. Edit them in Dosa Notes.")
                            .appFont(.caption)
                        Spacer()
                    }
                    .foregroundStyle(Theme.secondaryTextColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
                MarkdownTextEditor(
                    text: note.manualText,
                    isEditable: current.enhancedMarkdown == nil,
                    highlight: editorHighlight,
                    bottomContentInset: Self.barBottomInset,
                    onMediaFileDrop: { requestAudio(.importFile($0)) },
                    onMediaDragChanged: { isDropTargeted = $0 }
                )
                .accessibilityLabel(current.enhancedMarkdown == nil ? "My notes, editable" : "My notes, read-only")
                .padding(.top, 2)
            }
        }
    }

    private func enhancedBinding(note: Binding<Note>) -> Binding<String> {
        Binding(
            get: { note.wrappedValue.enhancedMarkdown ?? "" },
            set: { note.wrappedValue.enhancedMarkdown = $0 }
        )
    }

    // MARK: - Floating bar

    static let tabHeight: CGFloat = 20
    private static let tabWidth: CGFloat = 60
    private static let panelWidth: CGFloat = 320

    /// Extra scroll space at the bottom of the editor so content clears the
    /// collapsed bar: record button (38) + 2×12 vertical padding (62) + the
    /// permanent tab (20) = 82, + the bar's own `.padding(.bottom, 14)` = 96,
    /// + ~6pt breathing room = 102. The open panel is transient and reserves
    /// nothing (§9d).
    static let barBottomInset: CGFloat = 102

    /// Computed rather than a `static let` (as the plain rounded rect was),
    /// because the silhouette now tracks the quick-settings panel's state.
    private var barShape: BarPedestalShape {
        BarPedestalShape(
            topWidth: showQuickSettings ? Self.panelWidth : Self.tabWidth,
            topHeight: topBoxHeight,
            topCornerRadius: 13,
            barCornerRadius: 30
        )
    }

    private func floatingBar(current: Note) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if showQuickSettings {
                    QuickSettingsPanel()
                        .frame(width: Self.panelWidth)
                        .transition(.opacity)
                }
                quickSettingsTab
            }
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: BarTopBoxHeightKey.self, value: geo.size.height)
                }
            }
            barContent(current: current)
                // Stays on the *bar's* top edge. Hung off the whole container it
                // would pin itself to the top of the tab instead, floating above
                // the bar it is reporting on.
                .overlay(alignment: .top) { chunkingProgressStrip }
        }
        .onPreferenceChange(BarTopBoxHeightKey.self) { topBoxHeight = $0 }
        .clipShape(barShape)
        .floatingChrome(in: barShape)
        .textCursorCarveOut()
        .padding(.bottom, 14)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showQuickSettings)
        .animation(.easeInOut(duration: 0.18), value: player.playingNoteId == noteId)
        .animation(.easeInOut(duration: 0.2), value: generator.transcriptionProgress)
    }

    private func barContent(current: Note) -> some View {
        VStack(spacing: 10) {
            if player.playingNoteId == noteId {
                scrubBar
            }
            mainBarRow(current: current)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    /// The pull-tab. It sits between the panel and the bar, so the same control
    /// is the handle when collapsed and the collapse affordance when open.
    private var quickSettingsTab: some View {
        Button {
            showQuickSettings.toggle()
        } label: {
            Image(systemName: showQuickSettings ? "chevron.down" : "chevron.up")
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .fontWeight(.medium)
                .foregroundStyle(Theme.secondaryTextColor)
                .frame(width: Self.tabWidth, height: Self.tabHeight)
                // The drawn silhouette (60×20, BarPedestalShape) stays fixed —
                // only the *hit* area grows, to clear the 24pt target guideline.
                .contentShape(OutsetRectangle(outset: 4))
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
        .help(showQuickSettings ? "Hide quick settings" : "Model and notes style")
        .accessibilityLabel(showQuickSettings ? "Hide quick settings" : "Show quick settings")
    }

    /// Hairline fill along the top inner edge of the pill, in the active theme accent.
    @ViewBuilder
    private var chunkingProgressStrip: some View {
        if let progress = generator.transcriptionProgress, generator.activeNoteId == noteId {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.current.accentColor.opacity(0.18))
                    Rectangle()
                        .fill(Theme.current.accentColor)
                        .frame(width: max(8, geo.size.width * min(max(progress, 0), 1)))
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 30)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Transcription progress")
            .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
        }
    }

    private var scrubBar: some View {
        HStack(spacing: 12) {
            Text(TimeFormatting.clock(player.currentTime))
                .appFont(.subheadline, monospacedDigit: true)
                .foregroundStyle(Theme.secondaryTextColor)
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.1)
            )
            .controlSize(.regular)
            .frame(minWidth: 300)
            .accessibilityLabel("Playback position")
            .accessibilityValue(TimeFormatting.spoken(player.currentTime))
            Text(TimeFormatting.clock(player.duration))
                .appFont(.subheadline, monospacedDigit: true)
                .foregroundStyle(Theme.secondaryTextColor)
            Button {
                player.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help("Stop playback")
            .accessibilityLabel("Stop playback")
        }
    }

    private func mainBarRow(current: Note) -> some View {
        HStack(spacing: 16) {
            recordButton(current: current)
            if isRecordingThisNote {
                RecordingWaveformView(levels: recorder.levelHistory)
                Text(TimeFormatting.clock(recorder.elapsed))
                    .appMonoFont(size: 15)
                    .foregroundStyle(Theme.current.dangerTextColor)
                    .accessibilityLabel("Recording, \(TimeFormatting.spoken(recorder.elapsed))")
            }
            if isImporting {
                ProgressView()
                    .controlSize(.small)
                Text("Importing…")
                    .appFont(.body)
                    .foregroundStyle(Theme.secondaryTextColor)
            }
            Divider()
                .frame(height: 28)
            if generator.activeNoteId == noteId && generator.phase != .idle {
                Button {
                    generator.cancel()
                } label: {
                    Label(
                        generator.phase == .transcribing ? "Stop Transcribing" : "Stop Generating",
                        systemImage: "stop.circle"
                    )
                    .foregroundStyle(Theme.current.dangerTextColor)
                }
                .buttonStyle(.bordered)
                .cursor(.pointingHand)
                .help("Cancel and discard this run")
            } else {
                Button(action: generate) {
                    Label(current.enhancedMarkdown == nil ? "Generate Notes" : "Re-generate",
                          systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canGenerate(current: current))
                .cursor(.pointingHand)
                .help(current.recordingFileName == nil && current.transcript == nil
                      ? "Record a meeting first"
                      : "Transcribe the recording and let Dosa generate structured notes")
            }
            Button {
                showTranscript = true
            } label: {
                Label("Full Transcript", systemImage: "text.bubble")
            }
            .buttonStyle(.bordered)
            .disabled(current.transcript == nil)
            .cursor(.pointingHand)
            .help(current.transcript == nil
                  ? "The transcript appears after you generate notes"
                  : "View the full speaker-labeled transcript")
            if generator.activeNoteId == noteId && generator.phase != .idle {
                ProgressView()
                    .controlSize(.small)
            }
            if notion.exportingNoteId == noteId {
                ProgressView()
                    .controlSize(.small)
                Text("Exporting to Notion…")
                    .appFont(.body)
                    .foregroundStyle(Theme.secondaryTextColor)
            }
            if current.transcript != nil || current.enhancedMarkdown != nil {
                Divider()
                    .frame(height: 28)
                Button {
                    showNoteSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .cursor(.pointingHand)
                .help("Search within this note and its transcript (⌘F)")
                .accessibilityLabel("Search within note")
                .popover(isPresented: $showNoteSearch, arrowEdge: .top) {
                    NoteSearchView(note: current) {
                        showNoteSearch = false
                    }
                }
            }
        }
        .controlSize(.large)
    }

    private func handleReveal(_ reveal: SearchCoordinator.Reveal?) {
        guard let reveal, reveal.noteId == noteId else { return }
        search.pendingReveal = nil
        let range = NSRange(location: reveal.location, length: reveal.length)
        switch reveal.field {
        case .title:
            break
        case .manual:
            viewMode = .myNotes
            editorHighlight = TextHighlight(id: reveal.id, range: range)
        case .enhanced:
            viewMode = .aiNotes
            editorHighlight = TextHighlight(id: reveal.id, range: range)
        case .transcript:
            transcriptHighlight = TextHighlight(id: reveal.id, range: range)
            showTranscript = true
        }
    }

    @ViewBuilder
    private func recordButton(current: Note) -> some View {
        if isRecordingThisNote {
            Button(action: stopRecording) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(.red))
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help("Stop recording")
            .accessibilityLabel("Stop recording")
        } else if let url = store.recordingURL(for: current) {
            let isPlaying = player.playingNoteId == noteId && player.isPlaying
            Button {
                if player.playingNoteId == noteId {
                    player.togglePlayPause()
                } else {
                    player.play(url: url, noteId: noteId)
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.current.onAccentColor)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.current.accentColor))
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .help(isPlaying ? "Pause playback" : "Play the meeting recording")
            .accessibilityLabel(isPlaying ? "Pause playback" : "Play the meeting recording")
        } else {
            Button(action: startRecording) {
                Image(systemName: "record.circle")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(recorder.isRecording ? .gray : .red))
            }
            .buttonStyle(.plain)
            .cursor(.pointingHand)
            .disabled(recorder.isRecording)
            .help(recorder.isRecording
                  ? "Already recording in another note"
                  : "Record meeting audio (your microphone + system audio)")
            .accessibilityLabel(recorder.isRecording ? "Already recording in another note" : "Start recording")
        }
    }

    // MARK: - Actions menu

    private func actionsMenu(current: Note) -> some View {
        Menu {
            Button {
                exportNotes(current)
            } label: {
                Label("Export Notes", systemImage: "square.and.arrow.up")
            }
            Button {
                exportTranscript(current)
            } label: {
                Label("Export Transcript", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(current.transcript == nil)
            Button {
                exportRecording(current)
            } label: {
                Label("Export Recording", systemImage: "waveform.circle")
            }
            .disabled(current.recordingFileName == nil)
            Divider()
            Button {
                exportToNotion(current)
            } label: {
                Label(current.notionPageId == nil ? "Export to Notion" : "Update in Notion",
                      systemImage: "arrow.up.right.square")
            }
            .disabled(!notion.canExport || notion.exportingNoteId != nil)
            .help(notion.canExport
                  ? "Send this note to your configured Notion destination"
                  : "Connect Notion and choose a destination in Settings first")
            if let urlString = current.notionPageURL, let notionURL = URL(string: urlString) {
                Button {
                    NSWorkspace.shared.open(notionURL)
                } label: {
                    Label("Open in Notion", systemImage: "arrow.up.forward.app")
                }
            }
            Divider()
            Menu {
                ForEach(templates.templates) { template in
                    Button(template.name) { store.applyTemplate(template, to: noteId) }
                }
            } label: {
                Label("Apply Template", systemImage: "list.bullet.rectangle")
            }
            .disabled(current.enhancedMarkdown != nil || templates.templates.isEmpty)
            .help(current.enhancedMarkdown != nil
                  ? "Notes have already been generated — manual notes are read-only"
                  : "Add a template's sections to this note and tell the AI what kind of meeting it is")
            Button(action: startImport) {
                Label("Import Audio or Video…", systemImage: "square.and.arrow.down")
            }
            .disabled(recorder.isRecording || isImporting)
            .help(recorder.isRecording
                  ? "Finish the recording first"
                  : "Attach an audio or video file you already have (you can also drop one onto the note)")
            if current.recordingFileName != nil {
                Button {
                    if var fresh = store.note(id: noteId) {
                        fresh.transcript = nil
                        store.update(fresh)
                    }
                    generate()
                } label: {
                    Label("Re-transcribe & Regenerate", systemImage: "arrow.clockwise")
                }
                .disabled(generator.phase != .idle)
            }
            Divider()
            if current.recordingFileName != nil {
                Button(role: .destructive) {
                    confirmDiscardRecording = true
                } label: {
                    Label("Discard Recording", systemImage: "waveform.badge.minus")
                }
            }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Note", systemImage: "trash")
            }
        } label: {
            // No frames, font, or padding: this is a toolbar item now, and the
            // toolbar's own control metrics are what line it up with the sidebar
            // toggle and the back arrow. Sizing it by hand is what would break
            // that alignment — the previous floating-pill version had to fight
            // the menu's metrics with resizable frames precisely because it was
            // not in the toolbar.
            Label("More actions", systemImage: "ellipsis.circle")
        }
        // Matches the back arrow's glyph. Set explicitly for the same reason it is
        // there: `ContentView`'s `.tint` does not reach the window toolbar. Read
        // straight from `Theme.current` rather than passed in, because this view
        // sits inside the `.id(themeRefreshTick)` group and is rebuilt on a theme
        // change — the back arrow's toolbar is applied outside it and is not.
        .foregroundStyle(Theme.current.accentColor)
        .help("More actions")
    }

    // MARK: - Behavior

    private var isRecordingThisNote: Bool {
        recorder.isRecording && recorder.recordingNoteId == noteId
    }

    private func canGenerate(current: Note) -> Bool {
        generator.phase == .idle
            && !recorder.isRecording
            && (current.recordingFileName != nil || current.transcript != nil)
    }

    /// Generation errors are only this note's business. Automatic mode can fail a
    /// note the user isn't looking at, and without the `errorNoteId` check that
    /// error would open a sheet over an unrelated note — or, with no note open,
    /// never be shown or cleared and then fire on the next note opened.
    private var errorPresented: Binding<Bool> {
        Binding(
            get: {
                localError != nil
                    || (generator.errorMessage != nil && generator.errorNoteId == noteId)
            },
            set: { presented in
                if !presented {
                    localError = nil
                    localErrorDetail = nil
                    generator.errorMessage = nil
                    generator.errorDetail = nil
                    generator.errorNoteId = nil
                }
            }
        )
    }

    private func replaceWarning(_ note: Note, kind: PendingNoteAction.Kind) -> String {
        let verb = kind.isImport ? "Importing here" : "Recording again here"
        return note.recordingFileName != nil
            ? "\(verb) replaces the audio and clears the transcript."
            : "\(verb) clears the transcript this note's generated notes came from."
    }

    /// The single gate in front of both ways of attaching audio: never write over
    /// existing work without asking first.
    private func requestAudio(_ kind: PendingNoteAction.Kind) {
        guard let current = store.note(id: noteId) else { return }
        if current.existingWorkDescription != nil {
            pendingReplacement = kind
            return
        }
        begin(kind)
    }

    private func startRecording() {
        requestAudio(.record)
    }

    private func startImport() {
        guard let url = RecordingImporter.pickFile(for: .currentNote) else { return }
        requestAudio(.importFile(url))
    }

    private func begin(_ kind: PendingNoteAction.Kind) {
        switch kind {
        case .record: beginRecording()
        case .importFile(let url): beginImport(from: url)
        }
    }

    private func beginRecording() {
        player.stop()
        Task {
            do {
                try await recorder.start(destination: store.recordingDestination(for: noteId))
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func beginImport(from url: URL) {
        player.stop()
        appState.importingNoteIds.insert(noteId)
        Task {
            defer { appState.importingNoteIds.remove(noteId) }
            do {
                try await store.importRecording(from: url, into: noteId)
                let title = store.note(id: noteId)?.displayTitle ?? "Untitled Note"
                notifier.post(.recordingImported(noteId: noteId, title: title, fileName: url.lastPathComponent))
            } catch {
                localError = error.localizedDescription
                localErrorDetail = (error as? DetailedError)?.errorDetail
            }
        }
    }

    /// Leaves this note exactly as it is and starts over in a fresh note in the same
    /// folder. The new editor picks the request up in `onAppear`.
    private func startInNewNote(_ kind: PendingNoteAction.Kind) {
        player.stop()
        let folderId = store.note(id: noteId)?.folderId
        let note = store.createNote(in: folderId)
        appState.pendingNoteAction = PendingNoteAction(noteId: note.id, kind: kind)
        selectedNoteId = note.id
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !recorder.isRecording, !isImporting,
              let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                guard RecordingImporter.canImport(url) else {
                    // Say why rather than appearing to accept the file and doing nothing.
                    localError = "\"\(url.lastPathComponent)\" isn't an audio or video file Dosa can import."
                    return
                }
                requestAudio(.importFile(url))
            }
        }
        return true
    }

    /// Picks up a record/import request aimed at this note. Nils the field
    /// before acting so `onAppear` and `onChange` cannot both run it.
    private func consumePendingAction() {
        guard let pending = appState.pendingNoteAction, pending.noteId == noteId else { return }
        appState.pendingNoteAction = nil
        begin(pending.kind)
    }

    private func stopRecording() {
        RecordingCommand.stop(
            recorder: recorder,
            store: store,
            generator: generator,
            notifier: notifier
        ) { error in
            localError = error.localizedDescription
        }
    }

    private func generate() {
        let task = Task {
            await generator.run(noteId: noteId, store: store, notifier: notifier)
            if generator.errorMessage == nil, !Task.isCancelled,
               store.note(id: noteId)?.enhancedMarkdown != nil {
                viewMode = .aiNotes
            }
        }
        generator.register(task)
    }

    private func exportNotes(_ note: Note) {
        let body = note.enhancedMarkdown ?? note.manualText
        let markdown = """
        # \(note.displayTitle)

        *\(note.createdAt.formatted(date: .long, time: .omitted))*

        \(body)
        """
        saveToDownloads(markdown: markdown, baseName: note.displayTitle)
    }

    private func exportTranscript(_ note: Note) {
        guard let transcript = note.transcript else { return }
        let markdown = """
        # \(note.displayTitle) — Transcript

        *\(note.createdAt.formatted(date: .long, time: .omitted))*

        \(transcript)
        """
        saveToDownloads(markdown: markdown, baseName: "\(note.displayTitle) Transcript")
    }

    private func exportToNotion(_ note: Note) {
        Task {
            let wasUpdate = note.notionPageId != nil
            if await notion.export(note: note, store: store) {
                notifier.showToast(wasUpdate ? "Updated in Notion" : "Exported to Notion")
            } else if let message = notion.errorMessage {
                localErrorDetail = notion.errorDetail
                localError = message
            }
        }
    }

    private func exportRecording(_ note: Note) {
        guard let sourceURL = store.recordingURL(for: note),
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            localError = "The recording file could not be found."
            return
        }
        do {
            let url = try FileExporter.copyToDownloads(from: sourceURL, baseName: "\(note.displayTitle) Recording")
            notifier.showToast("Saved to Downloads as \(url.lastPathComponent)")
        } catch {
            localError = error.localizedDescription
        }
    }

    private func saveToDownloads(markdown: String, baseName: String) {
        do {
            let url = try FileExporter.saveToDownloads(markdown: markdown, baseName: baseName)
            notifier.showToast("Saved to Downloads as \(url.lastPathComponent)")
        } catch {
            localError = error.localizedDescription
        }
    }
}

/// `NSDatePicker`'s month grid with its chrome turned off.
///
/// `DatePicker(.graphical)` hosts this same control but exposes no way to reach
/// it, and inside a popover it arrives focused — so AppKit draws its accent-colored
/// focus ring around the calendar, plus a bezel under it. Neither belongs on a
/// surface that already has the popover's own border. `focusRingType = .none`
/// drops the ring without making the control unfocusable, so keyboard and
/// VoiceOver navigation still work; the bezel and background come off so the
/// popover's material shows through instead of a second card.
private struct BorderlessCalendarPicker: NSViewRepresentable {
    @Binding var selection: Date

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = [.yearMonthDay]
        picker.datePickerMode = .single
        picker.isBezeled = false
        picker.isBordered = false
        picker.drawsBackground = false
        picker.focusRingType = .none
        picker.dateValue = selection
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.dateChanged(_:))
        return picker
    }

    func updateNSView(_ nsView: NSDatePicker, context: Context) {
        context.coordinator.selection = $selection
        // Only write back on a real change: assigning `dateValue` unconditionally
        // fights the user mid-interaction.
        if nsView.dateValue != selection {
            nsView.dateValue = selection
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject {
        var selection: Binding<Date>

        init(selection: Binding<Date>) {
            self.selection = selection
        }

        /// `NSDatePicker` carries the whole date, so the note's time of day
        /// survives a day tap — `createdAt` orders the sidebar, and zeroing the
        /// time here would silently reshuffle the note list.
        @objc func dateChanged(_ sender: NSDatePicker) {
            selection.wrappedValue = sender.dateValue
        }
    }
}

/// The note-date calendar, drawn larger than `NSDatePicker`'s natural size.
///
/// `DatePicker(.graphical)` is an `NSDatePicker` underneath, so SwiftUI's font
/// environment does not reach it (§8) — there is no "make the calendar bigger"
/// knob, and the `.frame(width:)` this replaced only padded empty space around a
/// ~139pt-wide control. `scaleEffect` is the one mechanism that actually enlarges
/// it; on Retina the layer still rasterizes at 2× backing, so 1.3× resolves at
/// ~1.5× and stays crisp.
///
/// `scaleEffect` does not change measured size, so the natural size is read once
/// and multiplied back into a frame — otherwise the popover would size itself to
/// the unscaled control and clip.
private struct ScaledDatePicker: View {
    @Binding var selection: Date
    var scale: CGFloat = 1.3

    @State private var natural: CGSize = .zero

    var body: some View {
        BorderlessCalendarPicker(selection: $selection)
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { natural = proxy.size }
                        .onChange(of: proxy.size) { _, size in natural = size }
                }
            )
            .scaleEffect(scale, anchor: .topLeading)
            // Unconstrained until the first measurement lands, so the control is
            // never squeezed into a zero frame on the layout pass before it.
            .frame(
                width: natural.width > 0 ? natural.width * scale : nil,
                height: natural.height > 0 ? natural.height * scale : nil,
                alignment: .topLeading
            )
            .accessibilityLabel("Note date")
    }
}

/// A rectangle expanded past the view's own bounds — for `.contentShape(_:)`
/// only, to grow a tap target without changing the view's measured size (and
/// so, here, without changing what `BarPedestalShape` measures to draw).
private struct OutsetRectangle: Shape {
    var outset: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -outset, dy: -outset))
    }
}

enum FileExporter {
    static func saveToDownloads(markdown: String, baseName: String) throws -> URL {
        let url = uniqueDownloadsURL(baseName: baseName, fileExtension: "md")
        try Data(markdown.utf8).write(to: url)
        return url
    }

    static func copyToDownloads(from sourceURL: URL, baseName: String) throws -> URL {
        let url = uniqueDownloadsURL(baseName: baseName, fileExtension: sourceURL.pathExtension)
        try FileManager.default.copyItem(at: sourceURL, to: url)
        return url
    }

    private static func uniqueDownloadsURL(baseName: String, fileExtension: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        var name = baseName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Untitled Note" }

        var url = downloads.appendingPathComponent("\(name).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloads.appendingPathComponent("\(name) \(counter).\(fileExtension)")
            counter += 1
        }
        return url
    }
}
