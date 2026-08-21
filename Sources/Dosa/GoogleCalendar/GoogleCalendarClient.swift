import Foundation

final class GoogleCalendarClient: @unchecked Sendable {
    enum ClientError: LocalizedError, DetailedError {
        case unauthorized
        case http(Int, String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "Google rejected the Calendar connection. Reconnect your account in Settings."
            case .http(let status, _):
                return "The Google Calendar request failed (HTTP \(status))."
            case .malformed:
                return "Google Calendar returned an unexpected response."
            }
        }

        var errorDetail: String? {
            switch self {
            case .unauthorized:
                return nil
            case .http(_, let body), .malformed(let body):
                return body.isEmpty ? nil : String(body.prefix(4000))
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func listCalendars(accessToken: String) async throws -> [CalendarInfo] {
        let data = try await get(
            url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?maxResults=250")!,
            accessToken: accessToken
        )
        return try Self.parseCalendarList(data)
    }

    func listEvents(
        calendar: CalendarInfo,
        timeMin: Date,
        timeMax: Date,
        accessToken: String
    ) async throws -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(Self.encodeCalendarID(calendar.id))/events")!
            components.queryItems = [
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "250"),
                URLQueryItem(name: "timeMin", value: CalendarSyncWindow.rfc3339(timeMin)),
                URLQueryItem(name: "timeMax", value: CalendarSyncWindow.rfc3339(timeMax)),
                URLQueryItem(name: "conferenceDataVersion", value: "1"),
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            guard let url = components.url else {
                throw ClientError.malformed("could not build events URL")
            }
            let data = try await get(url: url, accessToken: accessToken)
            let page = try Self.parseEventPage(data, calendar: calendar)
            events.append(contentsOf: page.events)
            pageToken = page.nextPageToken
        } while pageToken != nil
        return events
    }

    static func parseCalendarList(_ data: Data) throws -> [CalendarInfo] {
        let decoded: GoogleCalendarListResponse
        do {
            decoded = try JSONDecoder().decode(GoogleCalendarListResponse.self, from: data)
        } catch {
            throw ClientError.malformed(String(data: data, encoding: .utf8) ?? error.localizedDescription)
        }
        return (decoded.items ?? [])
            .filter { $0.hidden != true && !$0.id.isEmpty }
            .map(CalendarInfo.init(entry:))
    }

    static func parseEventPage(_ data: Data, calendar: CalendarInfo) throws -> (events: [CalendarEvent], nextPageToken: String?) {
        let decoded: GoogleEventsListResponse
        do {
            decoded = try JSONDecoder().decode(GoogleEventsListResponse.self, from: data)
        } catch {
            throw ClientError.malformed(String(data: data, encoding: .utf8) ?? error.localizedDescription)
        }
        let events = (decoded.items ?? []).compactMap { CalendarEvent.from(api: $0, calendar: calendar) }
        return (events, decoded.nextPageToken)
    }

    static func encodeCalendarID(_ id: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    private func get(url: URL, accessToken: String) async throws -> Data {
        var lastError: Error = ClientError.malformed("request failed")
        for attempt in 0..<4 {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClientError.malformed("no HTTP response")
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ClientError.unauthorized
            }
            if http.statusCode == 429 {
                lastError = ClientError.http(429, String(decoding: data, as: UTF8.self))
                let delay = retryDelay(attempt: attempt, response: http)
                try await Task.sleep(nanoseconds: delay)
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ClientError.http(http.statusCode, String(decoding: data, as: UTF8.self))
            }
            return data
        }
        throw lastError
    }

    private func retryDelay(attempt: Int, response: HTTPURLResponse) -> UInt64 {
        if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(retryAfter) {
            return UInt64(max(seconds, 1) * 1_000_000_000)
        }
        return UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
    }
}
