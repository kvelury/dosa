import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    enum Event {
        case recordingSaved(noteId: UUID, title: String)
        case recordingImported(noteId: UUID, title: String, fileName: String)
        case notesReady(noteId: UUID, title: String)
    }

    /// The in-app message shown when Dosa is frontmost. Replaces NoteEditorView's
    /// private toast so it survives note switches.
    @Published private(set) var toast: String?
    /// Set when a banner is tapped; ContentView consumes it and clears it.
    @Published var pendingOpenNoteId: UUID?
    /// Drives the "macOS is blocking notifications" hint in Settings.
    @Published private(set) var authorizationDenied = false

    private var toastDismissTask: Task<Void, Never>?

    /// UNUserNotificationCenter.current() traps when there is no bundle identifier,
    /// which is the case running .build/release/Dosa directly instead of the .app.
    private static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    override init() {
        super.init()
        guard Self.isBundled else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ event: Event) {
        if NSApp.isActive {
            showToast(event.toastText, duration: event.toastDuration)
        } else {
            postBanner(event)
        }
    }

    /// Direct toast with no banner counterpart — for the export confirmations that
    /// already existed in NoteEditorView.
    func showToast(_ message: String, duration: TimeInterval = 2.8) {
        toastDismissTask?.cancel()
        withAnimation { toast = message }
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    private func postBanner(_ event: Event) {
        guard Self.isBundled, AppSettings.notificationsEnabled else { return }
        Task {
            guard await ensureAuthorized() else { return }
            let content = UNMutableNotificationContent()
            content.title = event.bannerTitle
            content.body = event.bannerBody
            content.sound = .default
            content.userInfo = ["noteId": event.noteId.uuidString]
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
            )
        }
    }

    /// Lazy, request-at-point-of-use — the same posture AudioRecorder and
    /// AppleTranscriber take for mic/screen/speech (see §4.1 of the design doc).
    @discardableResult
    func ensureAuthorized() async -> Bool {
        guard Self.isBundled else { return false }
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            authorizationDenied = false
            return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            authorizationDenied = !granted
            return granted
        default:
            authorizationDenied = true
            return false
        }
    }
}

extension NotificationManager.Event {
    var noteId: UUID {
        switch self {
        case .recordingSaved(let id, _), .recordingImported(let id, _, _), .notesReady(let id, _):
            return id
        }
    }

    var bannerTitle: String {
        switch self {
        case .recordingSaved, .recordingImported: return "Recording saved"
        case .notesReady: return "Notes ready"
        }
    }

    var bannerBody: String {
        switch self {
        case .recordingSaved(_, let title), .recordingImported(_, let title, _), .notesReady(_, let title):
            return title
        }
    }

    var toastText: String {
        switch self {
        case .recordingSaved:
            return "Recording saved"
        case .recordingImported(_, _, let fileName):
            guard Self.importLosesSpeakerLabels else { return "Imported \(fileName)" }
            return "Imported \(fileName) — on-device transcription can't separate speakers on imported files. Switch Transcription to Gemini in Settings for speaker names."
        case .notesReady:
            return "Notes ready"
        }
    }

    var toastDuration: TimeInterval {
        if case .recordingImported = self, Self.importLosesSpeakerLabels { return 6.5 }
        return 2.8
    }

    private static var importLosesSpeakerLabels: Bool {
        AppSettings.resolvedTranscriptionEngine != .gemini
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo["noteId"] as? String
        guard let id = raw.flatMap(UUID.init(uuidString:)) else { return }
        await MainActor.run {
            NSApp.activate()
            self.pendingOpenNoteId = id
        }
    }

    /// We only post when inactive; if Dosa came forward in between, stay quiet.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [] }
}
