import SwiftUI
import AppKit

struct CalendarEventDetailView: View {
    enum Style {
        case sheet
        case compact
    }

    @Environment(\.dismiss) private var dismiss

    let event: CalendarEvent
    var style: Style = .sheet
    var existingNote: Note? = nil
    var isRecording: Bool = false
    var onCreateNote: (() -> Void)? = nil
    var onCreateAndRecord: (() -> Void)? = nil
    var onOpenNote: ((Note) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(event.displayTitle)
                    .appFont(.title2, weight: .semibold)
                    .multilineTextAlignment(.leading)
                Spacer()
                if style == .sheet {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    labeled("When", timeSummary)
                    if !event.calendarName.isEmpty {
                        labeled("Calendar", event.calendarName)
                    }
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
                                .appFont(.caption, weight: .semibold)
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

            if style == .sheet {
                Divider()

                HStack {
                    Spacer()
                    if let existingNote {
                        Button("Open Note") {
                            onOpenNote?(existingNote)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.current.accentColor)
                    } else {
                        Button("Create Note") {
                            onCreateNote?()
                        }
                        Button("Create & Start Recording Note") {
                            onCreateAndRecord?()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.current.accentColor)
                        .disabled(isRecording)
                        .help(isRecording ? "Stop the current recording before starting another." : "Create a note for this meeting and start recording.")
                    }
                }
                .padding()
            }
        }
        .modifier(SizingModifier(style: style))
        .background(Theme.current.editorBackgroundColor)
        .appFontScope()
    }

    private var timeSummary: String {
        let date = event.start.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        guard event.start != event.end else { return date }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(date) · \(start) – \(end)"
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(.caption, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

private struct SizingModifier: ViewModifier {
    let style: CalendarEventDetailView.Style

    func body(content: Content) -> some View {
        switch style {
        case .sheet:
            content.frame(minWidth: 460, minHeight: 420)
        case .compact:
            content.frame(width: 380).frame(maxHeight: 360)
        }
    }
}
