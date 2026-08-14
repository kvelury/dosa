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
///   aren't subject to the ~1-minute server limit. Dictation sessions still
///   stop themselves after roughly a minute regardless, so `basicLines` feeds
///   the recognizer overlapping chunks rather than the whole file at once.
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

    /// The Mac itself is on macOS 26+, even if this binary was compiled
    /// against an older SDK that doesn't include SpeechAnalyzer.
    static var runningMacOS26: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    /// 0...1 as Basic chunking works through a long recording. Not called
    /// when the file fits in a single dictation window.
    typealias ProgressHandler = @Sendable (Double) async -> Void

    /// Transcribes the mixed recording. No speaker labels — every line is
    /// just `[mm:ss] text`.
    static func transcribe(
        audioURL: URL,
        engine: AppSettings.TranscriptionEngine,
        progress: ProgressHandler? = nil
    ) async throws -> String {
        let reporter = await chunkReporter(for: [audioURL], engine: engine, progress: progress)
        let lines = try await transcribeLines(audioURL: audioURL, engine: engine, reporter: reporter)
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
        userName: String,
        progress: ProgressHandler? = nil
    ) async throws -> String {
        let reporter = await chunkReporter(for: [micURL, systemURL], engine: engine, progress: progress)
        let micLines = try await transcribeLines(audioURL: micURL, engine: engine, reporter: reporter)
        let systemLines = try await transcribeLines(audioURL: systemURL, engine: engine, reporter: reporter)
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
        engine: AppSettings.TranscriptionEngine,
        reporter: ChunkReporter? = nil
    ) async throws -> [Line] {
        #if canImport(FoundationModels)
        if engine == .appleAdvanced, #available(macOS 26.0, *) {
            return try await advancedLines(audioURL: audioURL)
        }
        #endif
        return try await basicLines(audioURL: audioURL, reporter: reporter)
    }

    /// Counts overlapping 50 s windows the same way `basicLines` walks them,
    /// so the bar's denominator matches the work that will actually run.
    private static func chunkCount(for duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > chunkDuration else { return 1 }
        var count = 0
        var chunkStart: TimeInterval = 0
        while chunkStart < duration {
            count += 1
            let chunkEnd = min(chunkStart + chunkDuration, duration)
            if chunkEnd >= duration { break }
            chunkStart = chunkEnd - chunkOverlap
        }
        return count
    }

    private static func chunkReporter(
        for urls: [URL],
        engine: AppSettings.TranscriptionEngine,
        progress: ProgressHandler?
    ) async -> ChunkReporter? {
        guard let progress, engine != .appleAdvanced else { return nil }
        var total = 0
        for url in urls {
            let duration = CMTimeGetSeconds((try? await AVURLAsset(url: url).load(.duration)) ?? .zero)
            total += chunkCount(for: duration)
        }
        guard total > 1 else { return nil }
        let reporter = ChunkReporter(total: total, report: progress)
        await reporter.started()
        return reporter
    }

    private final class ChunkReporter: @unchecked Sendable {
        private let total: Int
        private let report: ProgressHandler
        private var completed = 0

        init(total: Int, report: @escaping ProgressHandler) {
            self.total = total
            self.report = report
        }

        func started() async {
            await report(0)
        }

        func advance() async {
            completed += 1
            await report(min(1, Double(completed) / Double(total)))
        }
    }

    // MARK: - Basic (SFSpeechRecognizer)

    /// A dictation session reliably transcribes only its first ~50 s before
    /// `isFinal` fires, so a long recording has to be fed in as several
    /// overlapping windows rather than one request.
    private static let chunkDuration: TimeInterval = 50
    /// Overlap between consecutive windows. If a chunk's session ends a few
    /// seconds early (dictation can fire `isFinal` before the full window is
    /// read), the next chunk still covers that lost tail because it starts
    /// this many seconds earlier.
    private static let chunkOverlap: TimeInterval = 8

    private static func basicLines(audioURL: URL, reporter: ChunkReporter?) async throws -> [Line] {
        try await requestAuthorization()

        let duration = CMTimeGetSeconds(try await AVURLAsset(url: audioURL).load(.duration))
        guard duration.isFinite, duration > 0 else {
            throw TranscriberError.recognitionFailed("Could not read the audio file's duration.")
        }
        guard duration > chunkDuration else {
            let lines = try await recognizeFile(audioURL)
            await reporter?.advance()
            return lines
        }

        var lines: [Line] = []
        var chunkStart: TimeInterval = 0
        while chunkStart < duration {
            try Task.checkCancellation()
            let chunkEnd = min(chunkStart + chunkDuration, duration)
            let chunkURL = try await exportChunk(from: audioURL, start: chunkStart, end: chunkEnd)
            defer { try? FileManager.default.removeItem(at: chunkURL) }

            let chunkLines = try await recognizeFile(chunkURL)
            lines.append(contentsOf: stitch(chunkLines, onto: chunkStart, droppingOverlap: chunkStart > 0))
            await reporter?.advance()

            if chunkEnd >= duration { break }
            chunkStart = chunkEnd - chunkOverlap
        }
        return lines
    }

    /// Maps a chunk's lines onto the full recording. When timestamps look
    /// usable, the overlapping head of later chunks is dropped so the same
    /// words aren't transcribed twice. On-device dictation often reports every
    /// segment at t=0 (or a single untimed blob); in that case the previous
    /// "floor" stitch dropped the entire later chunk and long recordings
    /// collapsed back to the first ~50 s.
    private static func stitch(_ chunkLines: [Line], onto chunkStart: TimeInterval, droppingOverlap: Bool) -> [Line] {
        let placed = chunkLines.map { (text: $0.text, start: chunkStart + $0.start) }
        guard droppingOverlap else { return placed }
        let maxRelative = chunkLines.map(\.start).max() ?? 0
        guard maxRelative >= chunkOverlap else { return placed }
        return chunkLines.compactMap { line in
            guard line.start >= chunkOverlap - 0.5 else { return nil }
            return (text: line.text, start: chunkStart + line.start)
        }
    }

    /// Exports the `[start, end)` slice of `url` to a standalone temporary
    /// audio file so it can be handed to its own recognition request.
    /// Uses the same composition+insertTimeRange path as `AudioRecorder.mix`,
    /// then checks the exported duration so a silent full-file re-export
    /// can't masquerade as a 50 s chunk.
    private static func exportChunk(from url: URL, start: TimeInterval, end: TimeInterval) async throws -> URL {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscriberError.recognitionFailed("The audio file has no audio track to chunk.")
        }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TranscriberError.recognitionFailed("Could not create a chunk composition.")
        }
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 60_000),
            duration: CMTime(seconds: max(0, end - start), preferredTimescale: 60_000)
        )
        try track.insertTimeRange(range, of: sourceTrack, at: .zero)

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriberError.recognitionFailed("Could not create a chunk export session.")
        }
        let chunkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(".dosa-transcribe-chunk-\(UUID().uuidString).m4a")
        session.outputURL = chunkURL
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else {
            throw TranscriberError.recognitionFailed(session.error?.localizedDescription ?? "Chunk export did not complete.")
        }
        let actual = CMTimeGetSeconds(try await AVURLAsset(url: chunkURL).load(.duration))
        let expected = end - start
        guard actual.isFinite, actual > 0, actual <= expected + 2 else {
            throw TranscriberError.recognitionFailed(
                "Chunk export produced \(String(format: "%.1f", actual))s of audio but \(String(format: "%.1f", expected))s was requested."
            )
        }
        return chunkURL
    }

    /// Runs one `SFSpeechURLRecognitionRequest` to completion and returns its
    /// lines with timestamps relative to the start of `audioURL` itself.
    /// A new recognizer is created per file: reusing one across sequential
    /// chunk requests often makes later sessions finish immediately empty.
    private static func recognizeFile(_ audioURL: URL) async throws -> [Line] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw TranscriberError.unavailable("SFSpeechRecognizer reported unavailable for the current locale.")
        }
        for _ in 0..<50 where !recognizer.isAvailable {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard recognizer.isAvailable else {
            throw TranscriberError.unavailable("SFSpeechRecognizer reported unavailable for the current locale.")
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        final class TaskBox: @unchecked Sendable {
            var task: SFSpeechRecognitionTask?
        }
        let box = TaskBox()
        // nil transcription = the file (or chunk) had no speech. Trailing
        // silence at the end of a long recording is common; treating it as
        // empty lets earlier chunks keep their text instead of failing the run.
        let transcription: SFTranscription? = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            var latest: SFTranscription?
            box.task = recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result {
                    latest = result.bestTranscription
                    if result.isFinal {
                        finished = true
                        box.task = nil
                        continuation.resume(returning: result.bestTranscription)
                        return
                    }
                }
                if let error {
                    finished = true
                    box.task = nil
                    // Some errors still arrive after usable output (e.g. trailing silence).
                    if let latest, !latest.formattedString.isEmpty {
                        continuation.resume(returning: latest)
                    } else if isNoSpeech(error) {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: mapped(error))
                    }
                }
            }
        }

        guard let transcription else { return [] }
        let segments = transcription.segments.map { (text: $0.substring, start: $0.timestamp) }
        guard !segments.isEmpty else {
            let whole = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            return whole.isEmpty ? [] : [(text: whole, start: 0)]
        }
        return groupIntoLines(segments)
    }

    /// On-device dictation uses this when a window is silence or near-silence
    /// (typical of the last chunk of a recording that trails off).
    private static func isNoSpeech(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 { return true }
        return nsError.localizedDescription.localizedCaseInsensitiveContains("no speech detected")
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
