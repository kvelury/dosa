import Foundation

/// Stable identity for a single occurrence of a calendar event.
/// Recurring instances share an iCal UID and are distinguished by start time.
struct CalendarEventIdentity: Hashable, Codable, Sendable {
    var iCalUID: String
    var instanceStart: Date

    init(iCalUID: String, instanceStart: Date) {
        self.iCalUID = iCalUID
        self.instanceStart = Date(timeIntervalSince1970: instanceStart.timeIntervalSince1970.rounded())
    }

    var key: String {
        "\(iCalUID)|\(instanceStart.timeIntervalSince1970)"
    }

    func matches(uid: String?, instanceStart: Date?) -> Bool {
        guard let uid, let instanceStart else { return false }
        return uid == iCalUID && abs(instanceStart.timeIntervalSince(self.instanceStart)) < 1
    }
}

struct CalendarAttendee: Hashable, Codable, Sendable {
    var email: String?
    var displayName: String
    var isSelf: Bool
    var isResource: Bool
    var responseStatus: String?

    var label: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return email ?? "Guest"
    }
}

struct CalendarInfo: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var isPrimary: Bool
    var accessRole: String
    var backgroundColor: String?
}

struct CalendarEvent: Identifiable, Hashable, Codable, Sendable {
    var identity: CalendarEventIdentity
    var googleEventID: String
    var calendarID: String
    var calendarName: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var timeZoneIdentifier: String?
    var status: String
    var selfResponseStatus: String?
    var attendees: [CalendarAttendee]
    var location: String?
    var descriptionHTML: String?
    var googleCalendarURL: URL?
    var meetingLinks: [URL]
    var eventType: String

    var id: String { identity.key }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled event" : trimmed
    }

    var otherAttendees: [CalendarAttendee] {
        attendees.filter { !$0.isSelf && !$0.isResource }
    }

    var descriptionPlainText: String {
        CalendarHTML.plainText(descriptionHTML ?? "")
    }
}

extension CalendarEvent {
    /// Rebuilt from the fields a note stored before snapshots existed, so the
    /// meeting chip still opens something useful on older notes.
    static func placeholder(for note: Note) -> CalendarEvent? {
        guard let uid = note.calendarEventUID,
              let instanceStart = note.calendarEventInstanceStart else { return nil }
        return CalendarEvent(
            identity: CalendarEventIdentity(iCalUID: uid, instanceStart: instanceStart),
            googleEventID: uid,
            calendarID: note.calendarID ?? "",
            calendarName: "",
            title: note.title,
            start: instanceStart,
            end: instanceStart,
            isAllDay: false,
            timeZoneIdentifier: nil,
            status: "confirmed",
            selfResponseStatus: nil,
            attendees: [],
            location: nil,
            descriptionHTML: nil,
            googleCalendarURL: note.calendarHTMLLink.flatMap(URL.init(string:)),
            meetingLinks: [],
            eventType: "default"
        )
    }
}

enum CalendarHTML {
    static func plainText(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var text = html
        text = text.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</p>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</div>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</li>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: "&#(\\d+);", with: "", options: .regularExpression)
        let lines = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        return lines
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CalendarLinkValidator {
    static func allowedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,);]}>\"'"))
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }

    static func httpLinks(in text: String) -> [URL] {
        guard !text.isEmpty else { return [] }
        let pattern = #"https?://[^\s<>"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let ns = text as NSString
        var seen = Set<String>()
        var urls: [URL] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: match.range)
            guard let url = allowedURL(from: raw) else { continue }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        return urls
    }
}

enum CalendarMeetingFilter {
    static let excludedEventTypes: Set<String> = [
        "focustime", "outofoffice", "workinglocation", "birthday"
    ]

    static func isMeeting(_ event: CalendarEvent) -> Bool {
        guard !event.isAllDay else { return false }
        if excludedEventTypes.contains(event.eventType.lowercased()) { return false }
        if event.status.lowercased() == "cancelled" { return false }
        if event.selfResponseStatus?.lowercased() == "declined" { return false }
        let hasOtherAttendee = event.attendees.contains { !$0.isSelf && !$0.isResource }
        return hasOtherAttendee || !event.meetingLinks.isEmpty
    }
}

enum CalendarEventDeduper {
    /// Keeps one copy of each occurrence. When the same invite appears on several
    /// selected calendars, the earliest ID in `preferredCalendarIDs` wins.
    static func dedupe(_ events: [CalendarEvent], preferredCalendarIDs: [String]) -> [CalendarEvent] {
        let rank: [String: Int] = Dictionary(uniqueKeysWithValues: preferredCalendarIDs.enumerated().map { ($0.element, $0.offset) })
        var best: [CalendarEventIdentity: CalendarEvent] = [:]
        for event in events {
            if let existing = best[event.identity] {
                let existingRank = rank[existing.calendarID] ?? Int.max
                let newRank = rank[event.calendarID] ?? Int.max
                if newRank < existingRank {
                    best[event.identity] = event
                }
            } else {
                best[event.identity] = event
            }
        }
        return best.values.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }
}

enum CalendarSyncWindow {
    static let dayCount = 30

    /// From `now` through the start of the day 30 calendar days later (exclusive).
    static func bounds(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let startOfToday = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: dayCount, to: startOfToday) ?? now.addingTimeInterval(TimeInterval(dayCount * 24 * 3600))
        return (now, end)
    }

    static func rfc3339(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: TimeZone(secondsFromGMT: 0) ?? .current)
    }
}

enum OAuthTokenTiming {
    static let refreshLeeway: TimeInterval = 60

    static func needsRefresh(expiry: Date?, now: Date = Date(), leeway: TimeInterval = refreshLeeway) -> Bool {
        guard let expiry else { return false }
        return expiry < now.addingTimeInterval(leeway)
    }
}

enum CalendarNoteLinking {
    static func activeNote<Note>(
        in notes: [Note],
        identity: CalendarEventIdentity,
        uid: KeyPath<Note, String?>,
        instanceStart: KeyPath<Note, Date?>,
        isDeleted: KeyPath<Note, Bool>
    ) -> Note? {
        notes.first { note in
            !note[keyPath: isDeleted] && identity.matches(
                uid: note[keyPath: uid],
                instanceStart: note[keyPath: instanceStart]
            )
        }
    }
}

private extension ISO8601DateFormatter {
    static func string(from date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }
}
