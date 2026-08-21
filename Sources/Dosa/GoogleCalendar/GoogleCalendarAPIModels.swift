import Foundation

struct GoogleCalendarListResponse: Codable {
    var items: [GoogleCalendarListEntry]?
}

struct GoogleCalendarListEntry: Codable {
    var id: String
    var summary: String?
    var primary: Bool?
    var accessRole: String?
    var backgroundColor: String?
    var hidden: Bool?
}

struct GoogleEventsListResponse: Codable {
    var items: [GoogleAPIEvent]?
    var nextPageToken: String?
}

struct GoogleAPIEvent: Codable {
    var id: String?
    var iCalUID: String?
    var status: String?
    var htmlLink: String?
    var summary: String?
    var description: String?
    var location: String?
    var start: GoogleDateTime?
    var end: GoogleDateTime?
    var attendees: [GoogleAttendee]?
    var hangoutLink: String?
    var conferenceData: GoogleConferenceData?
    var eventType: String?
    var recurringEventId: String?
    var originalStartTime: GoogleDateTime?
}

struct GoogleDateTime: Codable {
    var date: String?
    var dateTime: String?
    var timeZone: String?
}

struct GoogleAttendee: Codable {
    var email: String?
    var displayName: String?
    var resource: Bool?
    var organizer: Bool?
    var responseStatus: String?
    var isSelf: Bool?

    enum CodingKeys: String, CodingKey {
        case email, displayName, resource, organizer, responseStatus
        case isSelf = "self"
    }
}

struct GoogleConferenceData: Codable {
    var entryPoints: [GoogleEntryPoint]?
}

struct GoogleEntryPoint: Codable {
    var entryPointType: String?
    var uri: String?
}

enum GoogleDateParser {
    static func timestamp(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    static func allDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

extension CalendarInfo {
    init(entry: GoogleCalendarListEntry) {
        id = entry.id
        name = entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? entry.id
        isPrimary = entry.primary == true
        accessRole = entry.accessRole ?? ""
        backgroundColor = entry.backgroundColor
    }
}

extension CalendarEvent {
    static func from(api event: GoogleAPIEvent, calendar: CalendarInfo) -> CalendarEvent? {
        let isAllDay = event.start?.dateTime == nil && event.start?.date != nil
        guard let start = parseInstant(event.start) else { return nil }
        let end = parseInstant(event.end) ?? start.addingTimeInterval(3600)
        let uid = event.iCalUID?.nilIfEmpty ?? event.id ?? UUID().uuidString
        let attendees = (event.attendees ?? []).map { attendee in
            CalendarAttendee(
                email: attendee.email,
                displayName: attendee.displayName ?? "",
                isSelf: attendee.isSelf == true,
                isResource: attendee.resource == true,
                responseStatus: attendee.responseStatus
            )
        }
        return CalendarEvent(
            identity: CalendarEventIdentity(iCalUID: uid, instanceStart: start),
            googleEventID: event.id ?? uid,
            calendarID: calendar.id,
            calendarName: calendar.name,
            title: event.summary ?? "",
            start: start,
            end: end,
            isAllDay: isAllDay,
            timeZoneIdentifier: event.start?.timeZone,
            status: event.status ?? "confirmed",
            selfResponseStatus: attendees.first(where: \.isSelf)?.responseStatus,
            attendees: attendees,
            location: event.location?.nilIfEmpty,
            descriptionHTML: event.description,
            googleCalendarURL: event.htmlLink.flatMap(CalendarLinkValidator.allowedURL(from:)),
            meetingLinks: meetingLinks(from: event),
            eventType: event.eventType ?? "default"
        )
    }

    private static func parseInstant(_ value: GoogleDateTime?) -> Date? {
        guard let value else { return nil }
        if let dateTime = value.dateTime {
            return GoogleDateParser.timestamp(dateTime)
        }
        if let date = value.date {
            return GoogleDateParser.allDay(date)
        }
        return nil
    }

    private static func meetingLinks(from event: GoogleAPIEvent) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        func append(_ raw: String?) {
            guard let raw, let url = CalendarLinkValidator.allowedURL(from: raw) else { return }
            if seen.insert(url.absoluteString).inserted {
                urls.append(url)
            }
        }
        append(event.hangoutLink)
        for entry in event.conferenceData?.entryPoints ?? [] {
            append(entry.uri)
        }
        for url in CalendarLinkValidator.httpLinks(in: event.location ?? "") {
            if seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        for url in CalendarLinkValidator.httpLinks(in: event.description ?? "") {
            if seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        return urls
    }
}

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
