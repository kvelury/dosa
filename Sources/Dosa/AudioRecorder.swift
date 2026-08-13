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
/// Both streams are written to temp files while recording, then mixed into a single
/// .m4a when the recording stops.
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var recordingNoteId: UUID?
    /// Rolling window of recent audio levels (0-1), newest last — drives the
    /// live waveform so the user can see that audio is actually being captured.
    @Published var levelHistory: [Float] = AudioRecorder.emptyLevels

    static let emptyLevels: [Float] = Array(repeating: 0, count: 7)

    private var stream: SCStream?
    private var micEngine: AVAudioEngine?
    private var systemFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private let sampleQueue = DispatchQueue(label: "com.dosa.audio.samples")
    private var timer: Timer?
    private var levelTimer: Timer?
    private var startedAt: Date?
    private var peakLevel: Float = 0   // written on sampleQueue only

    private var systemURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("dosa-system.caf") }
    private var micURL: URL { FileManager.default.temporaryDirectory.appendingPathComponent("dosa-mic.caf") }

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

    func start(noteId: UUID) async throws {
        guard !isRecording else { return }

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        guard micGranted else { throw RecorderError.micPermissionDenied }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw RecorderError.screenPermissionDenied
        }

        try? FileManager.default.removeItem(at: systemURL)
        try? FileManager.default.removeItem(at: micURL)

        do {
            try startMicCapture()
            try await startSystemAudioCapture()
        } catch {
            teardownCapture()
            throw error
        }

        await MainActor.run {
            self.recordingNoteId = noteId
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

    /// Stops recording and writes the mixed `.m4a` to `outputURL`. When
    /// `micTrackURL`/`systemTrackURL` are given, each source is also kept as
    /// its own `.m4a` — transcribing them separately is what lets on-device
    /// transcription attribute speech to the user vs. everyone else.
    func stop(outputURL: URL, micTrackURL: URL? = nil, systemTrackURL: URL? = nil) async throws -> TimeInterval {
        guard isRecording else { return 0 }
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0

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

        try await Self.mix(inputs: [micURL, systemURL], to: outputURL)

        // Best-effort: a failed side track only costs speaker attribution, so
        // it must never fail the recording itself.
        if let micTrackURL {
            try? await Self.mix(inputs: [micURL], to: micTrackURL)
        }
        if let systemTrackURL {
            try? await Self.mix(inputs: [systemURL], to: systemTrackURL)
        }

        await MainActor.run { self.recordingNoteId = nil }
        return duration
    }

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: micURL, settings: format.settings)
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

    private static func mix(inputs: [URL], to outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
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
        session.outputURL = outputURL
        session.outputFileType = .m4a
        await session.export()
        if session.status != .completed {
            throw RecorderError.exportFailed(session.error?.localizedDescription ?? "The audio export did not complete.")
        }
    }
}

extension AudioRecorder: SCStreamDelegate, SCStreamOutput {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.isRecording = false
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              sampleBuffer.numSamples > 0,
              let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }

        if systemFile == nil {
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: description.mSampleRate,
                channels: AVAudioChannelCount(description.mChannelsPerFrame)
            ) else { return }
            systemFile = try? AVAudioFile(forWriting: systemURL, settings: format.settings)
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
