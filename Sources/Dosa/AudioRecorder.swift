import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics

/// Records a meeting by capturing two streams simultaneously, without ever joining the
/// meeting as a participant:
///   1. the microphone (what you say), via AVAudioEngine
///   2. system output audio (what everyone else says — Zoom, Meet, Teams, Slack huddles,
///      browser tabs, video files, anything the Mac plays), via ScreenCaptureKit's
///      OS-level audio loopback
/// Both streams are written to scratch files while recording, then mixed into a single
/// .m4a when the recording stops.
///
/// Captured audio is treated as irreplaceable: scratch files are keyed by note and kept
/// in the app's own directory (not the temp dir, which the OS purges), a session that
/// dies on its own is salvaged rather than dropped, and nothing already on disk is
/// deleted until its replacement has been written successfully.
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var recordingNoteId: UUID?
    /// Rolling window of recent audio levels (0-1), newest last — drives the
    /// live waveform so the user can see that audio is actually being captured.
    @Published var levelHistory: [Float] = AudioRecorder.emptyLevels
    /// Set when a capture ends on its own instead of via `stop()` — most often the
    /// system audio stream dying mid-meeting. Whatever was captured is salvaged
    /// first; the app observes this to save it and tell the user.
    @Published var interruption: Interruption?

    static let emptyLevels: [Float] = Array(repeating: 0, count: 7)

    /// Every file a recording session touches. Scratch files are keyed by note so two
    /// notes can never clobber each other's audio, and they survive a relaunch so an
    /// interrupted meeting can be recovered.
    struct Destination {
        let noteId: UUID
        let fileName: String
        let output: URL
        let micTrack: URL
        let systemTrack: URL
        let micScratch: URL
        let systemScratch: URL
    }

    /// A finished recording. `duration` is measured from the audio itself rather than
    /// the wall clock, so the time shown in the UI always matches what plays back.
    struct Recording {
        let noteId: UUID
        let fileName: String
        let duration: TimeInterval
    }

    struct Interruption: Identifiable, Equatable {
        let id = UUID()
        let message: String
        /// The salvaged audio, or nil when nothing could be recovered.
        let recovered: RecoveredRecording?

        static func == (lhs: Interruption, rhs: Interruption) -> Bool { lhs.id == rhs.id }
    }

    struct RecoveredRecording: Equatable {
        let noteId: UUID
        let fileName: String
        let duration: TimeInterval
    }

    private var stream: SCStream?
    private var micEngine: AVAudioEngine?
    private var systemFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private let sampleQueue = DispatchQueue(label: "com.dosa.audio.samples")
    private var timer: Timer?
    private var levelTimer: Timer?
    private var startedAt: Date?
    private var peakLevel: Float = 0   // written on sampleQueue only
    private var destination: Destination?

    /// Guards the hand-off between a user-driven `stop()` and a stream that dies on
    /// its own: whichever gets here first owns finishing the session, so the audio is
    /// never mixed twice or dropped by both paths assuming the other handled it.
    private let stateLock = NSLock()
    private var sessionActive = false

    enum RecorderError: LocalizedError {
        case micPermissionDenied
        case screenPermissionDenied
        case noDisplay
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .micPermissionDenied:
                return "Microphone access is required to record your side of the meeting. Enable it in System Settings → Privacy & Security → Microphone, then try again."
            case .screenPermissionDenied:
                return "Dosa captures meeting audio through the system audio loopback, which requires Screen & System Audio Recording permission. Grant it in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch Dosa and try again."
            case .noDisplay:
                return "No display found to attach the system audio capture to."
            case .exportFailed(let message):
                return "Could not save the recording: \(message)"
            }
        }
    }

    func start(destination: Destination) async throws {
        // Claimed synchronously, before the first `await`. `isRecording` doesn't flip
        // until setup finishes, and setup can sit for seconds on permission prompts —
        // a second Record click landing in that window would otherwise start a whole
        // second capture on top of the first.
        guard beginSession() else { return }

        do {
            let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
            guard micGranted else { throw RecorderError.micPermissionDenied }

            if !CGPreflightScreenCaptureAccess() {
                CGRequestScreenCaptureAccess()
                throw RecorderError.screenPermissionDenied
            }

            self.destination = destination
            try startMicCapture(to: destination.micScratch)
            try await startSystemAudioCapture()
        } catch {
            teardownCapture()
            self.destination = nil
            _ = claimSession()
            throw error
        }

        await MainActor.run {
            self.recordingNoteId = destination.noteId
            self.isRecording = true
            self.elapsed = 0
            self.levelHistory = Self.emptyLevels
            self.startedAt = Date()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let start = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
            self.levelTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                self?.shiftLevelHistory()
            }
        }
    }

    /// Returns false when a session is already in flight, so the caller must bail out.
    private func beginSession() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !sessionActive else { return false }
        sessionActive = true
        return true
    }

    /// Returns true to the first caller to claim the session; everyone after gets false.
    private func claimSession() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sessionActive else { return false }
        sessionActive = false
        return true
    }

    private func shiftLevelHistory() {
        sampleQueue.async { [weak self] in
            guard let self else { return }
            let level = self.peakLevel
            self.peakLevel *= 0.5
            DispatchQueue.main.async {
                guard self.isRecording else { return }
                var history = self.levelHistory
                history.removeFirst()
                history.append(min(1, level))
                self.levelHistory = history
            }
        }
    }

    private func registerLevel(rms: Float) {
        // Called on sampleQueue. Scale speech-range RMS (~0.02-0.2) up to 0-1.
        let scaled = min(1, rms * 7)
        if scaled > peakLevel {
            peakLevel = scaled
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        var count = 0
        for index in stride(from: 0, to: frames, by: 8) {
            let sample = channelData[index]
            sum += sample * sample
            count += 1
        }
        return count > 0 ? sqrt(sum / Float(count)) : 0
    }

    /// Stops recording and writes the mixed `.m4a` to the destination. Each source is
    /// also kept as its own `.m4a` — transcribing them separately is what lets
    /// on-device transcription attribute speech to the user vs. everyone else.
    func stop() async throws -> Recording {
        guard let destination, claimSession() else {
            throw RecorderError.exportFailed("This recording has already finished.")
        }
        let duration = try await finish(destination: destination)
        return Recording(noteId: destination.noteId, fileName: destination.fileName, duration: duration)
    }

    /// Tears the capture down, mixes what was captured, and clears the scratch files.
    /// The caller must already have won `claimSession()`.
    private func finish(destination: Destination) async throws -> TimeInterval {
        await MainActor.run {
            self.timer?.invalidate()
            self.timer = nil
            self.levelTimer?.invalidate()
            self.levelTimer = nil
            self.isRecording = false
            self.levelHistory = Self.emptyLevels
        }

        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // Close both files on the sample queue so pending writes flush first.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sampleQueue.async {
                self.micFile = nil
                self.systemFile = nil
                continuation.resume()
            }
        }

        let duration = try await Self.mix(
            inputs: [destination.micScratch, destination.systemScratch],
            to: destination.output
        )

        // Best-effort: a failed side track only costs speaker attribution, so
        // it must never fail the recording itself.
        _ = try? await Self.mix(inputs: [destination.micScratch], to: destination.micTrack)
        _ = try? await Self.mix(inputs: [destination.systemScratch], to: destination.systemTrack)

        // Only now that the mix is safely on disk is the raw capture disposable.
        try? FileManager.default.removeItem(at: destination.micScratch)
        try? FileManager.default.removeItem(at: destination.systemScratch)

        await MainActor.run {
            self.recordingNoteId = nil
            self.destination = nil
        }
        return duration
    }

    /// Called when the capture dies without the user asking it to. Salvages whatever
    /// was recorded rather than leaving the user with nothing.
    private func handleUnexpectedStop(message: String) {
        guard let destination, claimSession() else { return }
        Task {
            let duration = try? await finish(destination: destination)
            let recovered = duration.map {
                RecoveredRecording(noteId: destination.noteId, fileName: destination.fileName, duration: $0)
            }
            await MainActor.run {
                self.interruption = Interruption(message: message, recovered: recovered)
            }
        }
    }

    private func startMicCapture(to url: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        micFile = file
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let rms = Self.rms(of: buffer)
            self.sampleQueue.async {
                try? self.micFile?.write(from: buffer)
                self.registerLevel(rms: rms)
            }
        }
        engine.prepare()
        try engine.start()
        micEngine = engine
    }

    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Video is unavoidable overhead of an SCStream; shrink it to nothing.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.showsCursor = false

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await newStream.startCapture()
        stream = newStream
    }

    private func teardownCapture() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        sampleQueue.async {
            self.micFile = nil
            self.systemFile = nil
        }
    }

    /// Mixes `inputs` into `outputURL` and returns the resulting duration. The export
    /// runs to a staging file and only replaces `outputURL` once it has succeeded, so
    /// a failed export can never destroy the recording that was already there.
    @discardableResult
    static func mix(inputs: [URL], to outputURL: URL) async throws -> TimeInterval {
        let composition = AVMutableComposition()
        var addedTrack = false

        for url in inputs where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let duration = try await asset.load(.duration)
            guard duration > .zero else { continue }
            guard let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: assetTrack, at: .zero)
            addedTrack = true
        }

        guard addedTrack else { throw RecorderError.exportFailed("No audio was captured.") }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.exportFailed("Could not create the audio export session.")
        }

        let staging = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(".dosa-export-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: staging) }

        session.outputURL = staging
        session.outputFileType = .m4a
        await session.export()
        if session.status != .completed {
            throw RecorderError.exportFailed(session.error?.localizedDescription ?? "The audio export did not complete.")
        }

        // Read the duration back off the exported file rather than trusting the
        // export. A truncated result has to surface as a loud failure — with the raw
        // capture left untouched on disk — instead of a note whose stated length and
        // actual audio disagree.
        let expected = CMTimeGetSeconds(composition.duration)
        let actual = CMTimeGetSeconds(try await AVURLAsset(url: staging).load(.duration))
        guard actual.isFinite, actual >= min(expected - 1, expected * 0.98) else {
            throw RecorderError.exportFailed(
                "The export produced \(TimeFormatting.clock(actual)) of audio but \(TimeFormatting.clock(expected)) was recorded. The raw capture has been kept."
            )
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: outputURL)
        }
        return actual
    }
}

extension AudioRecorder: SCStreamDelegate, SCStreamOutput {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleUnexpectedStop(
            message: "The system audio capture stopped unexpectedly (\(error.localizedDescription)). Everything recorded up to that point has been saved to this note."
        )
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              sampleBuffer.numSamples > 0,
              let scratchURL = destination?.systemScratch,
              let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }

        if systemFile == nil {
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: description.mSampleRate,
                channels: AVAudioChannelCount(description.mChannelsPerFrame)
            ) else { return }
            systemFile = try? AVAudioFile(forWriting: scratchURL, settings: format.settings)
        }
        guard let file = systemFile,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: description.mSampleRate,
                channels: AVAudioChannelCount(description.mChannelsPerFrame)
              ) else { return }

        do {
            try sampleBuffer.withAudioBufferList { bufferList, _ in
                guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: bufferList.unsafePointer) else { return }
                try file.write(from: pcmBuffer)
                registerLevel(rms: Self.rms(of: pcmBuffer))
            }
        } catch {
            // Drop the buffer; a single failed write shouldn't kill the recording.
        }
    }
}
