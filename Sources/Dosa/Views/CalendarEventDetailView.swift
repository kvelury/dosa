import SwiftUI
import AppKit

struct CalendarEventDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let event: CalendarEvent
    let existingNote: Note?
    let isRecording: Bool
    let onCreateNote: () -> Void
    let onCreateAndRecord: () -> Void
    let onOpenNote: (Note) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(event.displayTitle)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeled("When", timeSummary)
                    labeled("Calendar", event.calendarName)
                    if !event.otherAttendees.isEmpty {
                        labeled("Attendees", event.otherAttendees.map(\.label).joined(separator: ", "))
                    }
                    if let location = event.location {
                        labeled("Location", location)
                    }
                    if !event.descriptionPlainText.isEmpty {
                        labeled("Description", event.descriptionPlainText)
                    }
                    if !event.meetingLinks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Meeting links")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(event.meetingLinks, id: \.absoluteString) { url in
                                Button(url.absoluteString) {
                                    NSWorkspace.shared.open(url)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    if let calendarURL = event.googleCalendarURL {
                        Button("Open in Google Calendar") {
                            NSWorkspace.shared.open(calendarURL)
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                Spacer()
                if let existingNote {
                    Button("Open Note") {
                        onOpenNote(existingNote)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.current.accentColor)
                } else {
                    Button("Create Note") {
                        onCreateNote()
                    }
                    Button("Create & Start Recording Note") {
                        onCreateAndRecord()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.current.accentColor)
                    .disabled(isRecording)
                    .help(isRecording ? "Stop the current recording before starting another." : "Create a note for this meeting and start recording.")
                }
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 420)
        .background(Theme.current.editorBackgroundColor)
    }

    private var timeSummary: String {
        let date = event.start.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(date) · \(start) – \(end)"
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
