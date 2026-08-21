import Foundation

struct CalendarCacheSnapshot: Codable {
    var accountEmail: String?
    var calendars: [CalendarInfo]
    var selectedCalendarIDs: [String]
    var events: [CalendarEvent]
    var lastSuccessfulSyncAt: Date?
    var failedCalendarIDs: [String]
}

enum CalendarCache {
    static func fileURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("calendar-cache.json")
    }

    static func load(from url: URL) -> CalendarCacheSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CalendarCacheSnapshot.self, from: data)
    }

    static func save(_ snapshot: CalendarCacheSnapshot, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

enum CalendarSyncReducer {
    /// Replaces events for calendars that succeeded and keeps cached events for ones that failed.
    static func merge(
        cached: [CalendarEvent],
        freshByCalendar: [String: [CalendarEvent]],
        failedCalendarIDs: Set<String>
    ) -> [CalendarEvent] {
        var grouped = Dictionary(grouping: cached, by: \.calendarID)
        for (calendarID, events) in freshByCalendar {
            grouped[calendarID] = events
        }
        for calendarID in grouped.keys where !freshByCalendar.keys.contains(calendarID) && !failedCalendarIDs.contains(calendarID) {
            grouped[calendarID] = []
        }
        return grouped.values.flatMap { $0 }
    }

    static func eventsAfterFailedRefresh(current: [CalendarEvent]) -> [CalendarEvent] {
        current
    }
}
