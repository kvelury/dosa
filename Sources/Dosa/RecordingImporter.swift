import Foundation
import AppKit
import UniformTypeIdentifiers

/// Brings an audio or video file the user already has into a note, as an alternative
/// to recording a meeting live.
///
/// Rather than maintaining a list of formats, this accepts whatever AVFoundation can
/// decode and lets a failed conversion say so. Every import is transcoded to `.m4a`,
/// which is what makes an imported file indistinguishable from a recording everywhere
/// downstream: `GeminiClient` hardcodes the `audio/mp4` mime type, and the on-device
/// engines can't open a video container at all.
enum RecordingImporter {
    /// System-defined umbrella types — `.audio` covers mp3/m4a/wav/aiff/flac/aac/caf,
    /// `.movie` covers mp4/mov/m4v. Notable gap: AVFoundation can't demux WebM or Ogg,
    /// so those reach `ImportError.noAudioTrack` with a clear message.
    static let contentTypes: [UTType] = [.audio, .movie]

    /// Where the file is headed, which is all that differs between entry points.
    enum Destination {
        /// The sidebar's + and ⌘O, which both spin up a note around the file.
        case newNote
        /// The ⋯ menu, which attaches to the note already open.
        case currentNote

        var message: String {
            switch self {
            case .newNote: return "Choose an audio or video file to create notes from."
            case .currentNote: return "Choose an audio or video file to attach to this note."
            }
        }
    }

    static func canImport(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return contentTypes.contains { type.conforms(to: $0) }
    }

    static func pickFile(for destination: Destination) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.title = "Import Audio or Video"
        panel.prompt = "Import"
        panel.message = destination.message
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

enum ImportError: LocalizedError, DetailedError {
    case noAudioTrack(String, detail: String?)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack(let name, _):
            return "Dosa couldn't read any audio from \"\(name)\". It may be a video with no audio track, or a format macOS can't decode (WebM and Ogg files aren't supported)."
        }
    }

    var errorDetail: String? {
        switch self {
        case .noAudioTrack(_, let detail):
            return detail
        }
    }
}
