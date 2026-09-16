import Foundation
import AVFoundation
import CoreMedia
#if canImport(FoundationModels)
import Speech
#endif

/// Streams the recording's two audio sources (microphone + system audio) through
/// on-device SpeechAnalyzer sessions while the meeting is still happening, so the
/// editor can show a running transcript. On stop, the accumulated finalized lines
/// are formatted exactly like `AppleTranscriber.transcribe(micURL:systemURL:...)`
/// output and become the note's final transcript — nothing is retranscribed.
///
/// macOS 26+ only (SpeechAnalyzer). Everything here is best-effort garnish on top
/// of the recording: any failure tears the live pipeline down and the recording
/// continues untouched, falling back to the normal post-hoc transcription path.
final class LiveTranscriber: ObservableObject, @unchecked Sendable {

    /// One rendered transcript line. Volatile lines (`isFinal == false`) are the
    /// recognizer's in-flight guess for the current utterance and keep mutating
    /// until the recognizer commits them.
    struct LiveLine: Identifiable, Equatable {
        let id: UUID
        let speaker: String
        let start: TimeInterval
        /// Monotonic insertion order — tiebreak for sorting, so lines with equal
        /// timestamps don't shuffle between UI updates.
        let seq: Int
        var text: String
        var isFinal: Bool
    }

    /// Sorted by start time (seq as tiebreak). Main-actor only.
    @Published private(set) var lines: [LiveLine] = []
    @Published private(set) var isActive = false
    /// Set once when the pipeline fails or can't start; observed for a toast.
    @Published var failureMessage: String?

    /// The tier this session started with. Read at `start` rather than at stop so
    /// changing the setting mid-recording can't change what happens to the text
    /// already on screen.
    private(set) var speed: AppSettings.LiveTranscriptionSpeed = .accurate

    // Cross-thread state. `sessionsLock` guards the session references so the
    // recorder's sample queue can hand buffers over without touching the main actor.
    private let sessionsLock = NSLock()
    private var micSessionBox: Any?
    private var systemSessionBox: Any?

    // Main-actor bookkeeping for assembling the final transcript.
    private var finalsBySpeaker: [String: [(text: String, start: TimeInterval)]] = [:]
    private var volatileLineId: [String: UUID] = [:]
    private var lastVolatilePublish: [String: Date] = [:]
    private var lastStart: [String: TimeInterval] = [:]
    private var nextSeq = 0
    private var userLabel = "You"

    // MARK: - Lifecycle

    /// Spins up both streaming sessions (downloading the speech model first if
    /// needed). On failure, sets `failureMessage` and stays inactive — the caller
    /// records normally.
    @MainActor
    func start(userName: String) async {
        guard !isActive else { return }
        failureMessage = nil
        lines = []
        finalsBySpeaker = [:]
        volatileLineId = [:]
        lastVolatilePublish = [:]
        lastStart = [:]
        nextSeq = 0
        userLabel = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "You" : userName
        speed = AppSettings.liveTranscriptionSpeed

        guard AppleTranscriber.advancedAvailable else {
            failureMessage = "Live transcription needs macOS 26 or later."
            return
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let tier = speed
                let mic = try await StreamSession.make(speaker: userLabel, speed: tier) { [weak self] update in
                    self?.apply(update)
                }
                let system = try await StreamSession.make(speaker: AppleTranscriber.othersLabel, speed: tier) { [weak self] update in
                    self?.apply(update)
                }
                storeSessions(mic: mic, system: system)
                isActive = true
            } catch {
                failureMessage = "Live transcription couldn't start (\(error.localizedDescription)). Recording continues — the transcript will be generated when you stop."
            }
        }
        #endif
    }

    /// Called on the recorder's sample queue. Must stay O(buffer): convert, yield, return.
    func ingestMic(_ buffer: AVAudioPCMBuffer) {
        ingest(buffer, boxKeyPath: \.micSessionBox)
    }

    /// Called on the recorder's sample queue (system-audio buffers wrap the sample
    /// buffer's own memory, so the conversion here — which copies — must happen
    /// synchronously before the callback returns).
    func ingestSystem(_ buffer: AVAudioPCMBuffer) {
        ingest(buffer, boxKeyPath: \.systemSessionBox)
    }

    private func ingest(_ buffer: AVAudioPCMBuffer, boxKeyPath: ReferenceWritableKeyPath<LiveTranscriber, Any?>) {
        let box = withSessionsLock { self[keyPath: boxKeyPath] }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), let session = box as? StreamSession {
            session.ingest(buffer)
        }
        #endif
    }

    /// The lock is only ever taken inside these three synchronous helpers: the
    /// sample queue and the main actor both reach the session references through
    /// them, and no `await` can land while the lock is held.
    private func withSessionsLock<T>(_ body: () -> T) -> T {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return body()
    }

    private func storeSessions(mic: Any?, system: Any?) {
        withSessionsLock {
            micSessionBox = mic
            systemSessionBox = system
        }
    }

    /// Finalizes both sessions and returns the formatted transcript, or nil when
    /// live mode wasn't running, ran in a preview-only tier, or produced nothing
    /// usable. Returning nil is what routes the note back through the normal
    /// post-meeting transcription path.
    @MainActor
    func finishIfActive() async -> String? {
        guard isActive else { return nil }
        isActive = false
        defer { clearSessions() }
        // Fast and Lightweight trade accuracy for latency, so their text is for
        // watching the meeting, not for keeping. Nothing to finalize or wait on —
        // dropping the sessions outright also makes stopping quicker.
        guard speed.liveTranscriptIsFinal else {
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let (mic, system) = currentSessions()
                mic?.cancel()
                system?.cancel()
            }
            #endif
            return nil
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let (mic, system) = currentSessions()
            await mic?.finish()
            await system?.finish()

            let micLines = finalsBySpeaker[userLabel] ?? []
            let systemLines = finalsBySpeaker[AppleTranscriber.othersLabel] ?? []
            // Without headphones the mic also hears the other participants —
            // same dedup as the post-hoc path.
            let deduped = micLines.filter { !AppleTranscriber.isEcho($0, of: systemLines) }
            let labeled = deduped.map { (label: userLabel, line: $0) }
                + systemLines.map { (label: AppleTranscriber.othersLabel, line: $0) }
            guard !labeled.isEmpty else { return nil }
            return labeled
                .sorted { $0.line.start < $1.line.start }
                .map { "**\($0.label)** [\(AppleTranscriber.mmss($0.line.start))]: \($0.line.text)" }
                .joined(separator: "\n")
        }
        #endif
        return nil
    }

    /// Tears everything down and discards the collected lines (start-failure and
    /// error paths — never the normal stop path).
    @MainActor
    func abort() {
        isActive = false
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let (mic, system) = currentSessions()
            mic?.cancel()
            system?.cancel()
        }
        #endif
        clearSessions()
        lines = []
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func currentSessions() -> (StreamSession?, StreamSession?) {
        withSessionsLock { (micSessionBox as? StreamSession, systemSessionBox as? StreamSession) }
    }
    #endif

    private func clearSessions() {
        storeSessions(mic: nil, system: nil)
    }

    // MARK: - Result handling (main actor)

    fileprivate enum Update {
        case volatileText(speaker: String, text: String, start: TimeInterval?)
        case finalText(speaker: String, text: String, start: TimeInterval?)
        case failed(speaker: String, message: String)
    }

    private func apply(_ update: Update) {
        Task { @MainActor in
            switch update {
            case .volatileText(let speaker, let text, let start):
                self.applyVolatile(speaker: speaker, text: text, start: start)
            case .finalText(let speaker, let text, let start):
                self.applyFinal(speaker: speaker, text: text, start: start)
            case .failed(_, let message):
                guard self.isActive else { return }
                self.failureMessage = "Live transcription stopped (\(message)). Recording continues — the transcript will be generated when you stop."
                self.abort()
            }
        }
    }

    @MainActor
    private func applyVolatile(speaker: String, text: String, start: TimeInterval?) {
        guard isActive, !text.isEmpty else { return }
        let resolvedStart = start ?? lastStart[speaker] ?? 0
        if let id = volatileLineId[speaker], let index = lines.firstIndex(where: { $0.id == id }) {
            // Coalesce: volatile updates can arrive many times a second, and each
            // publish re-renders the pane. Dropping intermediates is safe — the
            // next volatile (or the final) supersedes this text anyway.
            let now = Date()
            guard now.timeIntervalSince(lastVolatilePublish[speaker] ?? .distantPast) > 0.08 else { return }
            lastVolatilePublish[speaker] = now
            lines[index].text = text
        } else {
            let line = LiveLine(id: UUID(), speaker: speaker, start: resolvedStart, seq: nextSeq, text: text, isFinal: false)
            nextSeq += 1
            insert(line)
            volatileLineId[speaker] = line.id
            lastVolatilePublish[speaker] = Date()
        }
    }

    @MainActor
    private func applyFinal(speaker: String, text: String, start: TimeInterval?) {
        guard isActive, !text.isEmpty else { return }
        let resolvedStart = start ?? lastStart[speaker] ?? 0
        lastStart[speaker] = resolvedStart
        if let id = volatileLineId[speaker] {
            lines.removeAll { $0.id == id }
            volatileLineId[speaker] = nil
        }
        insert(LiveLine(id: UUID(), speaker: speaker, start: resolvedStart, seq: nextSeq, text: text, isFinal: true))
        nextSeq += 1
        finalsBySpeaker[speaker, default: []].append((text: text, start: resolvedStart))
    }

    @MainActor
    private func insert(_ line: LiveLine) {
        let index = lines.firstIndex {
            $0.start > line.start || ($0.start == line.start && $0.seq > line.seq)
        } ?? lines.endIndex
        lines.insert(line, at: index)
    }
}

// MARK: - StreamSession

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private final class StreamSession: @unchecked Sendable {
    /// The two module types share no result protocol member for their text, so
    /// which one is running is kept explicit and branched where it matters.
    enum Module {
        case transcriber(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var speechModule: any SpeechModule {
            switch self {
            case .transcriber(let module): return module
            case .dictation(let module): return module
            }
        }
    }

    private let speaker: String
    private let analyzer: SpeechAnalyzer
    private let module: Module
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let targetFormat: AVAudioFormat
    private var resultsTask: Task<Void, Never>?

    /// Guards `converter`/`stopped` — `ingest` runs on the recorder's sample
    /// queue while `finish`/`cancel` arrive from the main actor.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var stopped = false

    static func make(
        speaker: String,
        speed: AppSettings.LiveTranscriptionSpeed,
        onUpdate: @escaping @Sendable (LiveTranscriber.Update) -> Void
    ) async throws -> StreamSession {
        let module: Module
        switch speed {
        case .accurate, .fast:
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
                ?? Locale(identifier: "en-US")
            var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
            if speed == .fast { reporting.insert(.fastResults) }
            module = .transcriber(SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: reporting,
                attributeOptions: [.audioTimeRange]
            ))
        case .lightweight:
            let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current)
                ?? Locale(identifier: "en-US")
            module = .dictation(DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: [.audioTimeRange]
            ))
        }

        let speechModule = module.speechModule
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [speechModule]) {
            try await installation.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [speechModule]) else {
            throw AppleTranscriber.TranscriberError.unavailable("No compatible audio format for live transcription.")
        }

        // `.processLifetime` keeps the speech model resident once loaded, so a
        // second recording in the same session starts transcribing immediately
        // instead of paying the load again; `.userInitiated` keeps recognition
        // ahead of background work while the user is watching the text arrive.
        let analyzer = SpeechAnalyzer(
            modules: [speechModule],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)

        let session = StreamSession(
            speaker: speaker,
            analyzer: analyzer,
            module: module,
            continuation: inputBuilder,
            targetFormat: format
        )
        session.consumeResults(onUpdate: onUpdate)
        return session
    }

    private init(
        speaker: String,
        analyzer: SpeechAnalyzer,
        module: Module,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        targetFormat: AVAudioFormat
    ) {
        self.speaker = speaker
        self.analyzer = analyzer
        self.module = module
        self.continuation = continuation
        self.targetFormat = targetFormat
    }

    private func consumeResults(onUpdate: @escaping @Sendable (LiveTranscriber.Update) -> Void) {
        let speaker = self.speaker
        let module = self.module
        resultsTask = Task {
            func publish(text attributed: AttributedString, isFinal: Bool, range: CMTimeRange) {
                let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                let start = attributed.runs.compactMap { $0.audioTimeRange?.start.seconds }.first
                    ?? (range.start.isValid ? range.start.seconds : nil)
                if isFinal {
                    onUpdate(.finalText(speaker: speaker, text: text, start: start))
                } else {
                    onUpdate(.volatileText(speaker: speaker, text: text, start: start))
                }
            }

            do {
                switch module {
                case .transcriber(let transcriber):
                    for try await result in transcriber.results {
                        publish(text: result.text, isFinal: result.isFinal, range: result.range)
                    }
                case .dictation(let dictation):
                    for try await result in dictation.results {
                        publish(text: result.text, isFinal: result.isFinal, range: result.range)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                onUpdate(.failed(speaker: speaker, message: error.localizedDescription))
            }
        }
    }

    /// Sample-queue path. Converts into the analyzer's preferred format — which
    /// also copies the samples out of buffers that only borrow their memory —
    /// then hands the fresh buffer to the analyzer's input stream.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    /// Normal stop: drain the input, let the analyzer finalize everything it has,
    /// and wait for the results stream to run dry so every final line has landed.
    func finish() async {
        markStopped()
        continuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
        await resultsTask?.value
        resultsTask = nil
    }

    /// Error/abort path: stop as fast as possible, discarding pending audio.
    func cancel() {
        markStopped()
        continuation.finish()
        resultsTask?.cancel()
        resultsTask = nil
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    /// Closes the ingest gate. Synchronous by design: the sample queue reads
    /// `stopped` under the same lock, and no `await` may hold it.
    private func markStopped() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
#endif
