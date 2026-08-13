import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NoteEditorView: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var generator: GenerationManager
    @EnvironmentObject private var search: SearchCoordinator
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var notion: NotionManager

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
    @State private var isImporting = false
    @State private var isDropTargeted = false
    @State private var localError: String?
    @State private var localErrorDetail: String?
    @State private var toast: String?
    @State private var showNoteSearch = false
    @AppStorage(AppSettings.dosaColorKey) private var dosaColorName = "Theme Default"
    @AppStorage(AppSettings.themeKey) private var themeName = "Classic"
    @AppStorage(AppSettings.accentOverrideKey) private var accentOverride = "Theme Default"
    @State private var editorHighlight: TextHighlight?
    @State private var transcriptHighlight: TextHighlight?

    var body: some View {
        if let noteBinding = store.noteBinding(id: noteId) {
            editor(note: noteBinding)
        } else {
            WelcomeView()
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
            if let pending = appState.pendingNoteAction, pending.noteId == noteId {
                appState.pendingNoteAction = nil
                begin(pending.kind)
            }
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
        .overlay(alignment: .bottom) {
            floatingBar(current: current)
        }
        .overlay(alignment: .topTrailing) {
            actionsMenu(current: current)
                .padding(.top, 2)
                .padding(.trailing, 14)
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
            "This note already has \(existingWorkDescription(current) ?? "content")",
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
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func header(note: Binding<Note>, current: Note) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Untitled Note", text: note.title)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .bold))
                .padding(.trailing, 76)
            HStack(spacing: 14) {
                DatePicker("", selection: note.createdAt, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                if let duration = current.recordingDuration {
                    Label(TimeFormatting.clock(duration), systemImage: "waveform")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
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
                    .frame(width: 210)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func content(note: Binding<Note>, current: Note) -> some View {
        if viewMode == .aiNotes, current.enhancedMarkdown != nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Label("Your notes", systemImage: "circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Label("Dosa additions", systemImage: "circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(DiffEngine.aiColor)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 7)
                MarkdownTextEditor(
                    text: enhancedBinding(note: note),
                    diffAgainst: current.manualText,
                    highlight: editorHighlight,
                    bottomContentInset: 74,
                    onMediaFileDrop: { requestAudio(.importFile($0)) },
                    onMediaDragChanged: { isDropTargeted = $0 }
                )
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if current.enhancedMarkdown != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "lock")
                            .font(.caption)
                        Text("Read-only — Dosa has generated notes from these. Edit them in Dosa Notes.")
                            .font(.caption)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                }
                MarkdownTextEditor(
                    text: note.manualText,
                    isEditable: current.enhancedMarkdown == nil,
                    highlight: editorHighlight,
                    bottomContentInset: 74,
                    onMediaFileDrop: { requestAudio(.importFile($0)) },
                    onMediaDragChanged: { isDropTargeted = $0 }
                )
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

    private func floatingBar(current: Note) -> some View {
        VStack(spacing: 8) {
            if player.playingNoteId == noteId {
                scrubBar
            }
            mainBarRow(current: current)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .padding(.bottom, 14)
        .animation(.easeInOut(duration: 0.18), value: player.playingNoteId == noteId)
    }

    private var scrubBar: some View {
        HStack(spacing: 10) {
            Text(TimeFormatting.clock(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.1)
            )
            .controlSize(.small)
            .frame(minWidth: 260)
            Text(TimeFormatting.clock(player.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                player.stop()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop playback")
        }
    }

    private func mainBarRow(current: Note) -> some View {
        HStack(spacing: 14) {
            recordButton(current: current)
            if isRecordingThisNote {
                RecordingWaveformView(levels: recorder.levelHistory)
                Text(TimeFormatting.clock(recorder.elapsed))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.red)
            }
            if isImporting {
                ProgressView()
                    .controlSize(.small)
                Text("Importing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
                .frame(height: 22)
            if generator.activeNoteId == noteId && generator.phase != .idle {
                Button {
                    generator.cancel()
                } label: {
                    Label(
                        generator.phase == .transcribing ? "Stop Transcribing" : "Stop Generating",
                        systemImage: "stop.circle"
                    )
                    .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                .help("Cancel and discard this run")
            } else {
                Button(action: generate) {
                    Label(current.enhancedMarkdown == nil ? "Generate Notes" : "Re-generate",
                          systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canGenerate(current: current))
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if current.transcript != nil || current.enhancedMarkdown != nil {
                Divider()
                    .frame(height: 22)
                Button {
                    showNoteSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .help("Search within this note and its transcript (⌘F)")
                .popover(isPresented: $showNoteSearch, arrowEdge: .top) {
                    NoteSearchView(note: current) {
                        showNoteSearch = false
                    }
                }
            }
        }
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.red))
            }
            .buttonStyle(.plain)
            .help("Stop recording")
        } else if let url = store.recordingURL(for: current) {
            Button {
                if player.playingNoteId == noteId {
                    player.togglePlayPause()
                } else {
                    player.play(url: url, noteId: noteId)
                }
            } label: {
                Image(systemName: player.playingNoteId == noteId && player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.current.accentColor))
            }
            .buttonStyle(.plain)
            .help(player.playingNoteId == noteId && player.isPlaying ? "Pause playback" : "Play the meeting recording")
        } else {
            Button(action: startRecording) {
                Image(systemName: "record.circle")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(recorder.isRecording ? .gray : .red))
            }
            .buttonStyle(.plain)
            .disabled(recorder.isRecording)
            .help(recorder.isRecording
                  ? "Already recording in another note"
                  : "Record meeting audio (your microphone + system audio)")
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
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.large)
        .fixedSize()
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
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

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { localError != nil || generator.errorMessage != nil },
            set: { presented in
                if !presented {
                    localError = nil
                    localErrorDetail = nil
                    generator.errorMessage = nil
                    generator.errorDetail = nil
                }
            }
        )
    }

    /// What attaching new audio would destroy on this note, phrased for the prompt.
    /// Nil when the note is empty and the action is safe to run immediately.
    private func existingWorkDescription(_ note: Note) -> String? {
        let hasRecording = note.recordingFileName != nil
        let hasNotes = note.transcript != nil || note.enhancedMarkdown != nil
        switch (hasRecording, hasNotes) {
        case (true, true): return "a recording and generated notes"
        case (true, false): return "a recording"
        case (false, true): return "generated notes"
        case (false, false): return nil
        }
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
        if existingWorkDescription(current) != nil {
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
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                try await store.importRecording(from: url, into: noteId)
                showToast(importToastMessage(for: url), duration: importToastDuration)
            } catch {
                localError = error.localizedDescription
                localErrorDetail = (error as? DetailedError)?.errorDetail
            }
        }
    }

    /// Imported files have no `-mic`/`-system` side tracks, so on-device transcription
    /// falls back to unlabeled lines. Say so at import time rather than letting it be a
    /// surprise in the transcript.
    private var importLosesSpeakerLabels: Bool {
        AppSettings.resolvedTranscriptionEngine != .gemini
    }

    private var importToastDuration: TimeInterval { importLosesSpeakerLabels ? 6.5 : 2.8 }

    private func importToastMessage(for url: URL) -> String {
        let name = url.lastPathComponent
        guard importLosesSpeakerLabels else { return "Imported \(name)" }
        return "Imported \(name) — on-device transcription can't separate speakers on imported files. Switch Transcription to Gemini in Settings for speaker names."
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

    private func stopRecording() {
        Task {
            do {
                let recording = try await recorder.stop()
                store.setRecording(
                    noteId: recording.noteId,
                    fileName: recording.fileName,
                    duration: recording.duration
                )
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func generate() {
        let task = Task {
            await generator.run(noteId: noteId, store: store)
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
                showToast(wasUpdate ? "Updated in Notion" : "Exported to Notion")
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
            showToast("Saved to Downloads as \(url.lastPathComponent)")
        } catch {
            localError = error.localizedDescription
        }
    }

    private func saveToDownloads(markdown: String, baseName: String) {
        do {
            let url = try FileExporter.saveToDownloads(markdown: markdown, baseName: baseName)
            showToast("Saved to Downloads as \(url.lastPathComponent)")
        } catch {
            localError = error.localizedDescription
        }
    }

    private func showToast(_ message: String, duration: TimeInterval = 2.8) {
        withAnimation { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            withAnimation { toast = nil }
        }
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
