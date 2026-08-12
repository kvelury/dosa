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
    @Published var errorMessage: String?
    @Published var errorDetail: String?

    private var currentTask: Task<Void, Never>?

    func register(_ task: Task<Void, Never>) {
        currentTask = task
    }

    func cancel() {
        currentTask?.cancel()
    }

    func run(noteId: UUID, store: NotesStore) async {
        guard phase == .idle else { return }
        guard let note = store.note(id: noteId) else { return }

        let apiKey = (UserDefaults.standard.string(forKey: AppSettings.apiKeyKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            errorMessage = "Add your Gemini API key first — open Settings with the gear icon at the top of the sidebar."
            return
        }
        let model = AppSettings.resolveModel(
            AppSettings.string(forKey: AppSettings.modelKey, default: AppSettings.defaultModel)
        )
        let client = GeminiClient(apiKey: apiKey, model: model)

        activeNoteId = noteId
        defer {
            phase = .idle
            activeNoteId = nil
        }

        let userName = (UserDefaults.standard.string(forKey: AppSettings.userNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = userName.isEmpty ? "not provided (infer from the audio if possible)" : userName

        do {
            var transcript = note.transcript
            if transcript == nil {
                guard let audioURL = store.recordingURL(for: note),
                      FileManager.default.fileExists(atPath: audioURL.path) else {
                    errorMessage = "Record the meeting first, then generate notes."
                    return
                }
                phase = .transcribing
                let transcriptPrompt = AppSettings.string(
                    forKey: AppSettings.transcriptPromptKey, default: AppSettings.defaultTranscriptPrompt
                ).replacingOccurrences(of: "{{user_name}}", with: resolvedName)
                let result = try await client.transcribe(audioURL: audioURL, prompt: transcriptPrompt)
                transcript = Self.stripCodeFence(result)
                if var fresh = store.note(id: noteId) {
                    fresh.transcript = transcript
                    store.update(fresh)
                }
            }

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

            var markdown = Self.stripCodeFence(try await client.generateText(prompt: prompt))
            markdown = Self.stripLeadingTitleAndDate(markdown, title: latest.displayTitle)
            markdown = Self.normalizeBullets(markdown)
            if var fresh = store.note(id: noteId) {
                fresh.enhancedMarkdown = markdown
                store.update(fresh)
            }
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled {
                errorMessage = error.localizedDescription
                errorDetail = (error as? DetailedError)?.errorDetail
            }
        }
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
