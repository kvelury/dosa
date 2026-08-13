import Foundation
import Speech
import AVFoundation

/// On-device transcription via Apple's Speech frameworks.
///
/// Two tiers:
/// - **Advanced** — the macOS 26 `SpeechAnalyzer`/`SpeechTranscriber` API
///   (long-form model). Compiled in only when building against a macOS 26+
///   SDK (detected via `canImport(FoundationModels)`, a 26-only framework),
///   so this file still builds with older toolchains.
/// - **Basic** — `SFSpeechRecognizer`, available on the app's whole deployment
///   range. Dictation-grade; forced on-device when supported so long files
///   aren't subject to the ~1-minute server limit.
///
/// Neither tier does speaker diarization. Dosa gets two-way attribution a
/// different way: `AudioRecorder` keeps the microphone and system-audio
/// sources as separate files, so transcribing them independently tells the
/// user's voice apart from everyone else's. Individual remote participants
/// still can't be told apart — they share the system-audio track.
enum AppleTranscriber {

    /// One transcript line: text plus when it starts, in seconds.
    private typealias Line = (text: String, start: TimeInterval)

    static let othersLabel = "Others"

    enum TranscriberError: LocalizedError, DetailedError {
        case notAuthorized
        case dictationDisabled(String)
        case unavailable(String)
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Dosa isn't allowed to use Speech Recognition. Enable it in System Settings → Privacy & Security → Speech Recognition."
            case .dictationDisabled:
                return """
                On-Device (Basic) transcription uses macOS Dictation, which is turned off on this Mac.

                Turn it on in System Settings → Keyboard → Dictation (macOS downloads the speech model the first time), then generate notes again.
                """
            case .unavailable:
                return "On-device transcription isn't available on this Mac right now."
            case .recognitionFailed:
                return "On-device transcription failed."
            }
        }

        var errorDetail: String? {
            switch self {
            case .notAuthorized:
                return nil
            case .dictationDisabled(let detail), .unavailable(let detail), .recognitionFailed(let detail):
                return detail.isEmpty ? nil : detail
            }
        }
    }

    /// Whether the macOS 26 SpeechAnalyzer tier can run here (needs both a
    /// 26+ SDK at compile time and macOS 26+ at runtime).
    static var advancedAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Transcribes the mixed recording. No speaker labels — every line is
    /// just `[mm:ss] text`.
    static func transcribe(audioURL: URL, engine: AppSettings.TranscriptionEngine) async throws -> String {
        let lines = try await transcribeLines(audioURL: audioURL, engine: engine)
        guard !lines.isEmpty else { throw TranscriberError.recognitionFailed("The recognizer returned an empty transcript.") }
        return lines.map { "[\(mmss($0.start))] \($0.text)" }.joined(separator: "\n")
    }

    /// Transcribes the microphone and system-audio tracks separately and
    /// interleaves them by timestamp, so the user's turns are labeled with
    /// their name and everything the Mac played is labeled "Others".
    static func transcribe(
        micURL: URL,
        systemURL: URL,
        engine: AppSettings.TranscriptionEngine,
        userName: String
    ) async throws -> String {
        let micLines = try await transcribeLines(audioURL: micURL, engine: engine)
        let systemLines = try await transcribeLines(audioURL: systemURL, engine: engine)
        guard !micLines.isEmpty || !systemLines.isEmpty else {
            throw TranscriberError.recognitionFailed("The recognizer returned an empty transcript for both audio tracks.")
        }

        // Without headphones the mic also picks up the other participants, so
        // drop mic lines that echo a system line at the same moment.
        let deduped = micLines.filter { !isEcho($0, of: systemLines) }

        let labeled = deduped.map { (label: userName, line: $0) }
            + systemLines.map { (label: othersLabel, line: $0) }

        return labeled
            .sorted { $0.line.start < $1.line.start }
            .map { "**\($0.label)** [\(mmss($0.line.start))]: \($0.line.text)" }
            .joined(separator: "\n")
    }

    // MARK: - Engines

    private static func transcribeLines(
        audioURL: URL,
        engine: AppSettings.TranscriptionEngine
    ) async throws -> [Line] {
        #if canImport(FoundationModels)
        if engine == .appleAdvanced, #available(macOS 26.0, *) {
            return try await advancedLines(audioURL: audioURL)
        }
        #endif
        return try await basicLines(audioURL: audioURL)
    }

    // MARK: - Basic (SFSpeechRecognizer)

    private static func basicLines(audioURL: URL) async throws -> [Line] {
        try await requestAuthorization()

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw TranscriberError.unavailable("SFSpeechRecognizer reported unavailable for the current locale.")
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let transcription: SFTranscription = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var latest: SFTranscription?
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result {
                    latest = result.bestTranscription
                    if result.isFinal {
                        finished = true
                        continuation.resume(returning: result.bestTranscription)
                        return
                    }
                }
                if let error {
                    finished = true
                    // Some errors still arrive after usable output (e.g. trailing silence).
                    if let latest, !latest.formattedString.isEmpty {
                        continuation.resume(returning: latest)
                    } else {
                        continuation.resume(throwing: mapped(error))
                    }
                }
            }
        }

        let segments = transcription.segments.map { (text: $0.substring, start: $0.timestamp) }
        guard !segments.isEmpty else {
            let whole = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            return whole.isEmpty ? [] : [(text: whole, start: 0)]
        }
        return groupIntoLines(segments)
    }

    /// The speech daemon reports "Siri and Dictation are disabled"
    /// (kLSRErrorDomain 201) when macOS Dictation is off — the on-device
    /// recognizer *is* the Dictation model, so nothing works until it's on.
    private static func mapped(_ error: Error) -> TranscriberError {
        let nsError = error as NSError
        let detail = String(describing: error)
        if (nsError.domain == "kLSRErrorDomain" && nsError.code == 201)
            || nsError.localizedDescription.localizedCaseInsensitiveContains("dictation are disabled") {
            return .dictationDisabled(detail)
        }
        return .recognitionFailed(detail)
    }

    private static func requestAuthorization() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw TranscriberError.notAuthorized }
    }

    // MARK: - Advanced (SpeechAnalyzer, macOS 26+)

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func advancedLines(audioURL: URL) async throws -> [Line] {
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: audioURL)

        async let collected: [Line] = {
            var chunks: [Line] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.text.runs.compactMap { $0.audioTimeRange?.start.seconds }.first ?? 0
                chunks.append((text: text, start: start))
            }
            return chunks
        }()

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }
    #endif

    // MARK: - Formatting

    /// Groups word-level segments into lines, breaking on pauses (>1.2 s) or
    /// when a line spans more than ~25 s.
    private static func groupIntoLines(_ segments: [Line]) -> [Line] {
        guard !segments.isEmpty else { return [] }

        var lines: [Line] = []
        var words: [String] = []
        var lineStart = segments[0].start
        var previousStart = segments[0].start

        func flush() {
            guard !words.isEmpty else { return }
            lines.append((text: words.joined(separator: " "), start: lineStart))
            words = []
        }

        for segment in segments {
            if !words.isEmpty && (segment.start - previousStart > 1.2 || segment.start - lineStart > 25) {
                flush()
                lineStart = segment.start
            }
            words.append(segment.text)
            previousStart = segment.start
        }
        flush()
        return lines
    }

    /// True when a mic line looks like bleed of a nearby system-audio line —
    /// same moment, largely the same words.
    private static func isEcho(_ line: Line, of systemLines: [Line]) -> Bool {
        let words = tokens(line.text)
        guard !words.isEmpty else { return false }
        for candidate in systemLines where abs(candidate.start - line.start) <= 3 {
            let other = tokens(candidate.text)
            guard !other.isEmpty else { continue }
            let shared = words.intersection(other).count
            let similarity = Double(shared) / Double(min(words.count, other.count))
            if similarity >= 0.5 { return true }
        }
        return false
    }

    private static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }

    private static func mmss(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
