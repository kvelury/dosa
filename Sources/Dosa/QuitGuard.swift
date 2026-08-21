import AppKit

@MainActor
enum QuitGuard {
    /// What is in flight, empty when nothing is.
    static func runningWork(
        recorder: AudioRecorder,
        generator: GenerationManager,
        appState: AppState
    ) -> [String] {
        var work: [String] = []
        if recorder.isRecording {
            work.append("recording audio")
        }
        switch generator.phase {
        case .transcribing:
            work.append("transcribing a recording")
        case .generating:
            work.append("generating notes")
        case .idle:
            break
        }
        if !appState.importingNoteIds.isEmpty {
            work.append("importing a file")
        }
        return work
    }

    static func requestQuit(
        recorder: AudioRecorder,
        generator: GenerationManager,
        appState: AppState
    ) {
        let work = runningWork(
            recorder: recorder,
            generator: generator,
            appState: appState
        )
        guard !work.isEmpty else {
            NSApp.terminate(nil)
            return
        }

        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit while Dosa is \(work.joined(separator: " and "))?"
        alert.informativeText = """
            Quitting stops it immediately. An interrupted recording is recovered the next \
            time you open Dosa, but transcription, note generation, and imports will have \
            to start over.
            """
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    static func requestInstallUpdate(
        recorder: AudioRecorder,
        generator: GenerationManager,
        appState: AppState,
        extraWarnings: [String],
        onProceed: @escaping () -> Void
    ) {
        let work = runningWork(
            recorder: recorder,
            generator: generator,
            appState: appState
        )

        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = work.isEmpty
            ? "Install this update and restart Dosa?"
            : "Install update while Dosa is \(work.joined(separator: " and "))?"

        var paragraphs: [String] = []
        if !work.isEmpty {
            paragraphs.append("""
                Quitting stops it immediately. An interrupted recording is recovered the next \
                time you open Dosa, but transcription, note generation, and imports will have \
                to start over.
                """)
        }
        paragraphs.append("""
            Because Dosa is signed ad-hoc, macOS treats each new build as a different app. \
            After the restart you'll be asked again for Microphone and Screen & System Audio Recording, \
            and notifications may need re-approving.
            """)
        paragraphs.append(contentsOf: extraWarnings)
        alert.informativeText = paragraphs.joined(separator: "\n\n")
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            onProceed()
        }
    }
}
