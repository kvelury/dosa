import Foundation

/// Orchestrates the two LLM steps: speech-to-text with speaker identification,
/// then bi-directional note synthesis (transcript + the user's sparse manual notes
/// + note metadata are all folded into the generation prompt).
@MainActor
final class GenerationManager: ObservableObject {
    enum Phase {
        case idle
        case transcribing
        case generating
    }

    @Published var phase: Phase = .idle
    @Published var activeNoteId: UUID?
    /// 0...1 while On-Device (Basic) is walking overlapping chunks; nil
    /// otherwise (Gemini, Advanced, a file that fits in one window, or idle).
    @Published var transcriptionProgress: Double?
    @Published var errorMessage: String?
    @Published var errorDetail: String?
    /// The note `errorMessage` belongs to. Without it the editor would present
    /// whatever error is set on whichever note happens to be open — see the
    /// `errorPresented` gate in NoteEditorView.
    @Published var errorNoteId: UUID?

    private var currentTask: Task<Void, Never>?
    /// Notes waiting their turn in automatic mode. Only ever non-empty while a
    /// run is in flight, since `drain` is called synchronously on enqueue.
    private var queue: [UUID] = []

    func register(_ task: Task<Void, Never>) {
        currentTask = task
    }

    func cancel() {
        currentTask?.cancel()
    }

    /// Automatic mode's entry point: transcribe and generate this note without
    /// anyone pressing Generate Notes. Owns the settings gate so every caller
    /// gets the same rules.
    ///
    /// Queued rather than dropped when a run is already going, because a
    /// recording can be started while another note generates (`RecordingCommand`
    /// does not consult `phase`) and `run` would silently no-op on its
    /// `phase == .idle` guard.
    func enqueueAutomatic(noteId: UUID, store: NotesStore, notifier: NotificationManager) {
        guard AppSettings.automaticModeWillRun, !queue.contains(noteId) else { return }
        queue.append(noteId)
        drain(store: store, notifier: notifier)
    }

    private func drain(store: NotesStore, notifier: NotificationManager) {
        guard phase == .idle, !queue.isEmpty else { return }
        let noteId = queue.removeFirst()
        // Registered like any other run, so the floating bar's Stop button
        // cancels an automatic one too.
        let task = Task {
            await run(noteId: noteId, store: store, notifier: notifier, automatic: true)
            // Stop means stop. `Task {}` is unstructured and would not inherit
            // this task's cancellation, so without dropping the rest by hand,
            // cancelling one run would immediately start the next.
            guard !Task.isCancelled else {
                queue.removeAll()
                return
            }
            drain(store: store, notifier: notifier)
        }
        register(task)
    }

    private func setTranscriptionProgress(_ fraction: Double) {
        transcriptionProgress = fraction
    }

    /// `automatic` marks a run nobody is watching: the note may not be on screen,
    /// so failures are announced through `NotificationManager` as well as being
    /// stashed for the note's error sheet.
    func run(
        noteId: UUID,
        store: NotesStore,
        notifier: NotificationManager,
        automatic: Bool = false
    ) async {
        guard phase == .idle else { return }
        guard let note = store.note(id: noteId) else { return }

        // A fresh attempt invalidates any error stashed from an earlier one.
        // Only matters once runs can fail unseen: a manual failure is presented
        // and dismissed immediately, but an automatic one sits until the note is
        // opened, and would otherwise raise a stale sheet after a later success.
        if errorNoteId == noteId {
            errorMessage = nil
            errorDetail = nil
            errorNoteId = nil
        }

        let provider = AppSettings.currentProvider
        let geminiKey = AppSettings.storedAPIKey(for: "Gemini")
        let providerKey = AppSettings.storedAPIKey(for: provider)
        guard !providerKey.isEmpty else {
            fail(
                "Add your \(provider) API key first — open Settings with the gear icon at the top of the sidebar.",
                noteId: noteId,
                automatic: automatic,
                notifier: notifier,
                store: store
            )
            return
        }

        let providerModel = AppSettings.resolvedModel(for: provider)
        let transcriptionEngine = AppSettings.resolvedTranscriptionEngine
        // For Gemini-engine transcription only. Neither Anthropic nor DeepSeek
        // accepts audio, so the alternatives are the on-device Apple engines.
        // Pinned to the cheap flash tier rather than the user's generation
        // model — see AppSettings.transcriptionModel.
        let geminiTranscriber = GeminiClient(
            apiKey: geminiKey,
            model: AppSettings.transcriptionModel
        )
        let generateText: (String) async throws -> String
        switch provider {
        case "Anthropic":
            let client = AnthropicClient(apiKey: providerKey, model: providerModel)
            generateText = { try await client.generateText(prompt: $0) }
        case "DeepSeek":
            let client = DeepSeekClient(apiKey: providerKey, model: providerModel)
            generateText = { try await client.generateText(prompt: $0) }
        default:
            let client = GeminiClient(apiKey: providerKey, model: providerModel)
            generateText = { try await client.generateText(prompt: $0) }
        }

        activeNoteId = noteId
        defer {
            phase = .idle
            activeNoteId = nil
            transcriptionProgress = nil
        }

        let userName = (UserDefaults.standard.string(forKey: AppSettings.userNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = userName.isEmpty ? "not provided (infer from the audio if possible)" : userName

        do {
            var transcript = note.transcript
            if transcript == nil {
                guard let audioURL = store.recordingURL(for: note),
                      FileManager.default.fileExists(atPath: audioURL.path) else {
                    fail(
                        "Record the meeting first, then generate notes.",
                        noteId: noteId,
                        automatic: automatic,
                        notifier: notifier,
                        store: store
                    )
                    return
                }
                phase = .transcribing
                let reportProgress: AppleTranscriber.ProgressHandler = { [weak self] fraction in
                    await self?.setTranscriptionProgress(fraction)
                }
                let result: String
                if transcriptionEngine == .gemini {
                    guard !geminiKey.isEmpty else {
                        fail(
                            "Transcription is set to Gemini (Cloud), which needs a Gemini API key. Add one under Settings → LLM Provider → Gemini, or switch to an on-device engine in Settings → Transcription.",
                            noteId: noteId,
                            automatic: automatic,
                            notifier: notifier,
                            store: store
                        )
                        return
                    }
                    let transcriptPrompt = AppSettings.string(
                        forKey: AppSettings.transcriptPromptKey, default: AppSettings.defaultTranscriptPrompt
                    ).replacingOccurrences(of: "{{user_name}}", with: resolvedName)
                    result = try await geminiTranscriber.transcribe(audioURL: audioURL, prompt: transcriptPrompt)
                } else if let micURL = store.trackURL(for: note, .mic),
                          let systemURL = store.trackURL(for: note, .system) {
                    // Separate mic/system tracks were kept, so speech can be
                    // attributed to the user vs. the other participants.
                    result = try await AppleTranscriber.transcribe(
                        micURL: micURL,
                        systemURL: systemURL,
                        engine: transcriptionEngine,
                        userName: userName.isEmpty ? "You" : userName,
                        progress: reportProgress
                    )
                } else {
                    // Older recording with only the mixed file: timestamps, no labels.
                    result = try await AppleTranscriber.transcribe(
                        audioURL: audioURL,
                        engine: transcriptionEngine,
                        progress: reportProgress
                    )
                }
                transcript = Self.stripCodeFence(result)
                if var fresh = store.note(id: noteId) {
                    fresh.transcript = transcript
                    store.update(fresh)
                }
            }

            transcriptionProgress = nil
            phase = .generating
            let latest = store.note(id: noteId) ?? note
            let template = AppSettings.string(
                forKey: AppSettings.notesPromptKey, default: AppSettings.defaultNotesPrompt
            )
            let prompt = template
                .replacingOccurrences(of: "{{verbosity}}", with: AppSettings.verbosityInstruction(level: AppSettings.currentVerbosity))
                .replacingOccurrences(of: "{{user_name}}", with: resolvedName)
                .replacingOccurrences(of: "{{title}}", with: latest.displayTitle)
                .replacingOccurrences(of: "{{date}}", with: latest.createdAt.formatted(date: .long, time: .omitted))
                .replacingOccurrences(of: "{{manual_notes}}", with: latest.manualText.isEmpty ? "(none)" : latest.manualText)
                .replacingOccurrences(of: "{{transcript}}", with: transcript ?? "")

            var markdown = Self.stripCodeFence(try await generateText(prompt))
            markdown = Self.stripLeadingTitleAndDate(markdown, title: latest.displayTitle)
            markdown = Self.normalizeBullets(markdown)
            if var fresh = store.note(id: noteId) {
                fresh.enhancedMarkdown = markdown
                fresh.generationModel = providerModel
                fresh.generationStyle = AppSettings.verbosityLevelNames[AppSettings.currentVerbosity]
                store.update(fresh)
                notifier.post(.notesReady(noteId: noteId, title: fresh.displayTitle))
            }
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled {
                fail(
                    error.localizedDescription,
                    detail: (error as? DetailedError)?.errorDetail,
                    noteId: noteId,
                    automatic: automatic,
                    notifier: notifier,
                    store: store
                )
            }
        }
    }

    /// The single error exit. Always stashes the message for the note's error
    /// sheet; an automatic run additionally announces the failure, because the
    /// user may be in another note or another app and would otherwise only find
    /// out by opening the note. The message is kept rather than replaced by the
    /// notification so `ErrorDialogView` can still show the provider's raw
    /// response when they do open it.
    private func fail(
        _ message: String,
        detail: String? = nil,
        noteId: UUID,
        automatic: Bool,
        notifier: NotificationManager,
        store: NotesStore
    ) {
        errorMessage = message
        errorDetail = detail
        errorNoteId = noteId
        guard automatic else { return }
        let title = store.note(id: noteId)?.displayTitle ?? "Untitled Note"
        notifier.post(.notesFailed(noteId: noteId, title: title))
    }

    /// The title and date already live in the note header, so drop a leading
    /// "# <title>" heading (and a date-ish line right after it) if the model
    /// emits them anyway.
    private static func stripLeadingTitleAndDate(_ markdown: String, title: String) -> String {
        var lines = markdown.components(separatedBy: "\n")

        func dropLeadingEmptyLines() {
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
        }

        dropLeadingEmptyLines()
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("#") else {
            return markdown
        }
        let headingText = first.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        let isTopLevelHeading = first.hasPrefix("# ")
        let matchesTitle = headingText.caseInsensitiveCompare(title) == .orderedSame
        guard isTopLevelHeading || matchesTitle else { return markdown }

        lines.removeFirst()
        dropLeadingEmptyLines()

        if let next = lines.first?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*_")),
           !next.isEmpty, !next.hasPrefix("#"), !next.hasPrefix("-"), next.count < 60,
           next.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) != nil {
            lines.removeFirst()
            dropLeadingEmptyLines()
        }
        return lines.joined(separator: "\n")
    }

    /// Rewrite "*" and "+" list markers as "-" so a model's bullet asterisks can
    /// never pair with a stray "*" later in the line and read as italics.
    private static func normalizeBullets(_ markdown: String) -> String {
        markdown
            .components(separatedBy: "\n")
            .map { line in
                if let range = line.range(of: #"^(\s*)[*+](\s+)"#, options: .regularExpression) {
                    let prefix = line[range]
                        .replacingOccurrences(of: "*", with: "-")
                        .replacingOccurrences(of: "+", with: "-")
                    return prefix + line[range.upperBound...]
                }
                return line
            }
            .joined(separator: "\n")
    }

    private static func stripCodeFence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        if let firstNewline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        }
        if trimmed.hasSuffix("```") {
            trimmed = String(trimmed.dropLast(3))
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
