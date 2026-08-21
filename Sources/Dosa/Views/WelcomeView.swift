import SwiftUI

enum WelcomeGreeting {
    static func text(userName: String) -> String {
        let firstName = userName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .first ?? ""
        return firstName.isEmpty ? "Welcome to Dosa" : "Hi \(firstName), welcome to Dosa"
    }

    static var todayText: String {
        Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}

struct HomeView: View {
    @EnvironmentObject private var calendar: GoogleCalendarManager

    var body: some View {
        if calendar.isConnected {
            CalendarHomeView()
        } else {
            WelcomeView()
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var store: NotesStore
    @AppStorage(AppSettings.userNameKey) private var userName = ""
    @AppStorage(AppSettings.themeKey) private var themeName = "Classic"

    private var greeting: String {
        WelcomeGreeting.text(userName: userName)
    }

    var body: some View {
        ZStack {
            DosaWatermark(color: Theme.current.highlightColor)
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 26) {
                VStack(spacing: 10) {
                    Text(greeting)
                        .font(.system(size: 36, weight: .bold))
                        .multilineTextAlignment(.center)

                    Text("Record meetings straight from your Mac's audio — Zoom, Meet, Teams, Huddles, anything — jot quick notes, and let Dosa turn them into polished meeting notes.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }

                HStack(spacing: 14) {
                    StatCard(value: "\(store.activeNotes.count)", label: "Notes", icon: "note.text")
                    StatCard(value: "\(store.meetingsRecorded)", label: "Meetings Recorded", icon: "mic.fill")
                    StatCard(value: store.totalRecordedTimeText, label: "Time Recorded", icon: "clock")
                    StatCard(value: "\(store.notesGeneratedCount)", label: "Dosa Summaries", icon: "sparkles")
                }

                Text("Click + at the top of the sidebar to create your first note.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.current.editorBackgroundColor.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                HStack(spacing: 18) {
                    ShortcutHint(keys: "⌘ N", label: "New note")
                    ShortcutHint(keys: "⌘ R", label: "Start Recording")
                    ShortcutHint(keys: "⌘ O", label: "Import file")
                }
                HStack(spacing: 18) {
                    ShortcutHint(keys: "⌘ K", label: "Search everywhere")
                    ShortcutHint(keys: "⌘ F", label: "Search in note")
                    ShortcutHint(keys: "⌘ W", label: "Close note")
                }
            }
            .padding(.bottom, 18)
        }
    }
}

private struct ShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            Text(keys)
                .font(.system(size: 13, weight: .semibold).monospaced())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.current.cardFillColor))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                // Headroom for the longest label ("Start Recording") at minimum width.
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.current.highlightColor)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 10)
        .frame(width: 136, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.current.cardFillColor)
        )
    }
}
