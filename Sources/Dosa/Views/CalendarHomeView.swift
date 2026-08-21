import SwiftUI

struct CalendarHomeView: View {
    @EnvironmentObject private var store: NotesStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var calendar: GoogleCalendarManager
    @AppStorage(AppSettings.userNameKey) private var userName = ""
    @AppStorage(AppSettings.themeKey) private var themeName = "Classic"

    @State private var selectedEvent: CalendarEvent?

    private var dayGroups: [CalendarDayGroup] {
        CalendarDayGroup.groups(from: calendar.upcomingMeetings)
    }

    var body: some View {
        ZStack {
            DosaWatermark(color: Theme.current.highlightColor)
                .ignoresSafeArea(edges: .top)

            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 8) {
                    Text(WelcomeGreeting.text(userName: userName))
                        .appFont(.hero)
                        .multilineTextAlignment(.center)
                    Text(WelcomeGreeting.todayText)
                        .appFont(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                if let partial = calendar.partialFailureMessage {
                    statusLine(partial, retry: true)
                } else if calendar.isStale, calendar.lastSuccessfulSyncAt != nil {
                    statusLine("Showing saved meetings until Google Calendar refreshes.", retry: true)
                } else if let error = calendar.errorMessage, !calendar.upcomingMeetings.isEmpty {
                    statusLine(error, retry: true)
                }

                if calendar.upcomingMeetings.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(dayGroups) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(group.title)
                                        .appFont(.headline)
                                        .foregroundStyle(.secondary)
                                    ForEach(group.events) { event in
                                        Button {
                                            selectedEvent = event
                                        } label: {
                                            CalendarEventCard(event: event)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.current.editorBackgroundColor.ignoresSafeArea(edges: .top))
        .sheet(item: $selectedEvent) { event in
            CalendarEventDetailView(
                event: event,
                existingNote: store.activeNote(for: event.identity),
                isRecording: recorder.isRecording,
                onCreateNote: { openNote(store.openOrCreateNote(for: event)) },
                onCreateAndRecord: { createAndRecord(event) },
                onOpenNote: { note in openNote(note) }
            )
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            if calendar.isRefreshing && calendar.events.isEmpty {
                ProgressView()
                    .controlSize(.small)
                Text("Loading upcoming meetings…")
                    .appFont(.body)
                    .foregroundStyle(.secondary)
            } else if let error = calendar.errorMessage {
                Text(error)
                    .appFont(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await calendar.refresh() }
                }
            } else {
                Text("No upcoming meetings in the next 30 days.")
                    .appFont(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusLine(_ message: String, retry: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.current.highlightColor)
            Text(message)
                .appFont(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if retry {
                if calendar.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Refresh") {
                        Task { await calendar.refresh() }
                    }
                    .controlSize(.small)
                    .appFont(.subheadline)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.current.cardFillColor))
    }

    private func openNote(_ note: Note) {
        selectedEvent = nil
        appState.selectedNoteIds = [note.id]
    }

    private func createAndRecord(_ event: CalendarEvent) {
        if let existing = store.activeNote(for: event.identity) {
            openNote(existing)
            return
        }
        guard !recorder.isRecording else { return }
        let note = store.openOrCreateNote(for: event)
        appState.pendingNoteAction = PendingNoteAction(noteId: note.id, kind: .record)
        openNote(note)
    }
}

struct CalendarDayGroup: Identifiable {
    var id: Date
    var events: [CalendarEvent]

    var title: String {
        let calendar = Foundation.Calendar.current
        if calendar.isDateInToday(id) { return "Today" }
        if calendar.isDateInTomorrow(id) { return "Tomorrow" }
        return id.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    static func groups(from events: [CalendarEvent]) -> [CalendarDayGroup] {
        let calendar = Foundation.Calendar.current
        let grouped = Dictionary(grouping: events) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted().map { day in
            CalendarDayGroup(
                id: day,
                events: (grouped[day] ?? []).sorted { $0.start < $1.start }
            )
        }
    }
}

struct CalendarEventCard: View {
    let event: CalendarEvent

    private var isHappeningNow: Bool {
        let now = Date()
        return event.start <= now && event.end > now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.displayTitle)
                    .appFont(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if isHappeningNow {
                    Text("Now")
                        .appFont(.caption, weight: .semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.current.accentColor.opacity(0.18)))
                        .foregroundStyle(Theme.current.accentColor)
                }
            }
            Text(timeRange)
                .appFont(.subheadline, monospacedDigit: true)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label(event.calendarName, systemImage: "calendar")
                    .appFont(.caption)
                if !event.otherAttendees.isEmpty {
                    Label("\(event.otherAttendees.count)", systemImage: "person.2")
                        .appFont(.caption)
                }
                if event.location != nil {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.caption)
                }
                if !event.meetingLinks.isEmpty {
                    Image(systemName: "video")
                        .font(.caption)
                }
            }
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.current.cardFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var timeRange: String {
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}
