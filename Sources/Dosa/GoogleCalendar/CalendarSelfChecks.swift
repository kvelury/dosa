import Foundation

/// In-process checks for Calendar logic. Lives in DosaKit so it can see internal
/// types; invoked by the `DosaCalendarChecks` executable because this repo is
/// built with Command Line Tools (no XCTest).
public enum CalendarSelfChecks {
    public static func run() -> Int {
        var failures = 0
        func expect(_ condition: Bool, _ message: String, line: Int = #line) {
            if !condition {
                failures += 1
                fputs("FAIL CalendarSelfChecks.swift:\(line): \(message)\n", stderr)
            }
        }

        expect(CalendarMeetingFilter.isMeeting(event(attendees: [
            attendee(isSelf: true),
            attendee(email: "alex@example.com"),
        ])), "timed event with another attendee should be a meeting")

        var linked = event()
        linked.meetingLinks = [URL(string: "https://meet.google.com/abc-defg-hij")!]
        expect(CalendarMeetingFilter.isMeeting(linked), "timed event with a meeting link should be a meeting")
        expect(!CalendarMeetingFilter.isMeeting(event(attendees: [attendee(isSelf: true)])), "personal block without guests or link should be excluded")

        var allDay = event(attendees: [attendee(email: "alex@example.com")])
        allDay.isAllDay = true
        expect(!CalendarMeetingFilter.isMeeting(allDay), "all-day events should be excluded")
        for type in ["focusTime", "outOfOffice", "workingLocation", "birthday"] {
            var item = event(attendees: [attendee(email: "alex@example.com")])
            item.eventType = type
            expect(!CalendarMeetingFilter.isMeeting(item), "\(type) should be excluded")
        }
        var cancelled = event(attendees: [attendee(email: "alex@example.com")])
        cancelled.status = "cancelled"
        expect(!CalendarMeetingFilter.isMeeting(cancelled), "cancelled events should be excluded")
        var declined = event(attendees: [attendee(email: "alex@example.com")])
        declined.selfResponseStatus = "declined"
        expect(!CalendarMeetingFilter.isMeeting(declined), "declined events should be excluded")
        expect(!CalendarMeetingFilter.isMeeting(event(attendees: [
            attendee(isSelf: true),
            attendee(email: "room@example.com", isResource: true),
        ])), "resource attendees should not count as people")

        do {
            let calendars = try GoogleCalendarClient.parseCalendarList("""
            {"items":[
              {"id":"me@example.com","summary":"Krishna","primary":true,"accessRole":"owner"},
              {"id":"hidden@example.com","summary":"Hidden","hidden":true,"accessRole":"reader"}
            ]}
            """.data(using: .utf8)!)
            expect(calendars.map(\.id) == ["me@example.com"], "hidden calendars should be skipped")
            expect(calendars.first?.isPrimary == true, "primary calendar should be flagged")
        } catch {
            expect(false, "calendar list decode failed: \(error)")
        }

        do {
            let calendar = CalendarInfo(id: "me@example.com", name: "Krishna", isPrimary: true, accessRole: "owner", backgroundColor: nil)
            let page = try GoogleCalendarClient.parseEventPage("""
            {
              "nextPageToken": "page-2",
              "items": [{
                "id": "evt-1",
                "iCalUID": "uid-1@google.com",
                "status": "confirmed",
                "htmlLink": "https://calendar.google.com/event?eid=abc",
                "summary": "Design review",
                "description": "Agenda<br>Join at https://zoom.us/j/123",
                "location": "https://meet.google.com/aaa-bbbb-ccc",
                "start": {"dateTime": "2026-08-20T18:00:00-07:00"},
                "end": {"dateTime": "2026-08-20T19:00:00-07:00"},
                "hangoutLink": "https://meet.google.com/aaa-bbbb-ccc",
                "conferenceData": {"entryPoints": [{"entryPointType": "video", "uri": "https://meet.google.com/aaa-bbbb-ccc"}]},
                "attendees": [
                  {"email": "me@example.com", "displayName": "Me", "self": true, "responseStatus": "accepted"},
                  {"email": "alex@example.com", "displayName": "Alex", "responseStatus": "accepted"}
                ],
                "eventType": "default"
              }]
            }
            """.data(using: .utf8)!, calendar: calendar)
            expect(page.nextPageToken == "page-2", "next page token should round-trip")
            expect(page.events.count == 1, "one event on the page")
            let item = page.events[0]
            expect(item.displayTitle == "Design review", "title")
            expect(!item.isAllDay, "timed event")
            expect(item.otherAttendees.map(\.email) == ["alex@example.com"], "other attendees")
            expect(item.meetingLinks.contains(URL(string: "https://meet.google.com/aaa-bbbb-ccc")!), "meet link")
            expect(item.meetingLinks.contains(URL(string: "https://zoom.us/j/123")!), "description link")
            expect(CalendarMeetingFilter.isMeeting(item), "decoded meeting should pass the filter")

            let allDayEvent = try GoogleCalendarClient.parseEventPage("""
            {"items":[{
              "id":"all-day","iCalUID":"holiday","summary":"Holiday",
              "start":{"date":"2026-08-21"},"end":{"date":"2026-08-22"},"eventType":"default"
            }]}
            """.data(using: .utf8)!, calendar: calendar).events[0]
            expect(allDayEvent.isAllDay, "date-only start is all-day")
            expect(!CalendarMeetingFilter.isMeeting(allDayEvent), "all-day decoded event is not a meeting")
        } catch {
            expect(false, "event page decode failed: \(error)")
        }

        expect(
            GoogleCalendarClient.encodeCalendarID("en.usa#holiday@group.v.calendar.google.com")
                == "en.usa%23holiday%40group.v.calendar.google.com",
            "calendar IDs should be percent-encoded"
        )

        let start = Date(timeIntervalSince1970: 1_787_259_600)
        let identity = CalendarEventIdentity(iCalUID: "same@google.com", instanceStart: start)
        let work = event(identity: identity, calendarID: "work", calendarName: "Work", title: "Work copy")
        let personal = event(identity: identity, calendarID: "me", calendarName: "Personal", title: "Personal copy")
        let unique = event(title: "1:1")
        let deduped = CalendarEventDeduper.dedupe([work, personal, unique], preferredCalendarIDs: ["me", "work"])
        expect(deduped.filter { $0.identity == identity }.map(\.calendarID) == ["me"], "shared invite prefers primary")
        expect(deduped.count == 2, "unique events survive dedupe")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 7
        components.hour = 10
        let now = calendar.date(from: components)!
        let bounds = CalendarSyncWindow.bounds(now: now, calendar: calendar)
        expect(bounds.start == now, "window starts at now")
        let endDay = calendar.dateComponents([.year, .month, .day], from: bounds.end)
        expect(endDay.year == 2026 && endDay.month == 4 && endDay.day == 6, "30 calendar days later is April 6")
        expect(calendar.dateComponents([.hour], from: bounds.end).hour == 0, "end is start of day")

        expect(CalendarLinkValidator.allowedURL(from: "https://meet.google.com/abc") != nil, "https allowed")
        expect(CalendarLinkValidator.allowedURL(from: "http://example.com/call") != nil, "http allowed")
        expect(CalendarLinkValidator.allowedURL(from: "javascript:alert(1)") == nil, "javascript rejected")
        expect(CalendarLinkValidator.allowedURL(from: "file:///tmp/notes") == nil, "file rejected")
        expect(CalendarLinkValidator.allowedURL(from: "data:text/html,hi") == nil, "data rejected")
        expect(
            CalendarLinkValidator.httpLinks(in: "See https://zoom.us/j/1 and javascript:void(0)").map(\.absoluteString)
                == ["https://zoom.us/j/1"],
            "only http(s) links extracted"
        )
        expect(CalendarHTML.plainText("<p>Hello<br>world</p><script>alert(1)</script>") == "Hello\nworld", "HTML stripped, script dropped")

        let nowToken = Date(timeIntervalSince1970: 1_000)
        expect(OAuthTokenTiming.needsRefresh(expiry: nowToken.addingTimeInterval(30), now: nowToken), "refresh inside leeway")
        expect(!OAuthTokenTiming.needsRefresh(expiry: nowToken.addingTimeInterval(120), now: nowToken), "fresh token")
        expect(!OAuthTokenTiming.needsRefresh(expiry: nil, now: nowToken), "missing expiry is not treated as expired")

        let original = event(calendarID: "team", title: "Standup")
        let snapshot = CalendarCacheSnapshot(
            accountEmail: "me@example.com",
            calendars: [CalendarInfo(id: "me@example.com", name: "Krishna", isPrimary: true, accessRole: "owner", backgroundColor: nil)],
            selectedCalendarIDs: ["me@example.com"],
            events: [original],
            lastSuccessfulSyncAt: Date(timeIntervalSince1970: 100),
            failedCalendarIDs: ["team"]
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dosa-cal-cache-\(UUID().uuidString).json")
        CalendarCache.save(snapshot, to: url)
        expect(CalendarCache.load(from: url)?.events.map(\.displayTitle) == ["Standup"], "cache round-trip")
        expect(CalendarSyncReducer.eventsAfterFailedRefresh(current: [original]).map(\.id) == [original.id], "failed refresh keeps cache")
        let refreshed = event(calendarID: "me@example.com", title: "New")
        let merged = CalendarSyncReducer.merge(
            cached: [original],
            freshByCalendar: ["me@example.com": [refreshed]],
            failedCalendarIDs: ["team"]
        )
        expect(Set(merged.map { $0.displayTitle }) == Set(["Standup", "New"]), "partial refresh keeps failed calendar events")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dosa-notes-\(UUID().uuidString)", isDirectory: true)
        let store = NotesStore(dataDirectory: directory, recoverInterrupted: false)
        let meeting = event(title: "Interview")
        let first = store.openOrCreateNote(for: meeting)
        expect(first.title == "Interview", "prefill title")
        expect(store.openOrCreateNote(for: meeting).id == first.id, "reuse active linked note")
        store.moveToTrash(first.id)
        expect(store.activeNote(for: meeting.identity) == nil, "trashed note is not active")
        expect(store.note(id: first.id)?.calendarEventUID == nil, "trash detaches calendar link")
        let replacement = store.openOrCreateNote(for: meeting)
        expect(replacement.id != first.id, "replacement is a new note")
        expect(store.activeNote(for: meeting.identity)?.id == replacement.id, "replacement is the active link")
        store.restore(first.id)
        expect(store.note(id: first.id)?.calendarEventUID == nil, "restored note stays unlinked")
        expect(store.activeNote(for: meeting.identity)?.id == replacement.id, "restore does not steal the active link")

        // Calendar event snapshots on notes: round-trip, back-compat decode,
        // placeholder fallback, and live-refresh.
        do {
            var withSnapshot = Note(title: "Snapshot round-trip")
            withSnapshot.calendarEventUID = "snap@google.com"
            withSnapshot.calendarEventInstanceStart = Date(timeIntervalSince1970: 1_787_259_600)
            withSnapshot.calendarEventSnapshot = event(title: "Interview with XYZ")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                let data = try encoder.encode(withSnapshot)
                let decoded = try decoder.decode(Note.self, from: data)
                expect(decoded.calendarEventSnapshot?.displayTitle == "Interview with XYZ", "snapshot survives a round-trip")
            } catch {
                expect(false, "snapshot round-trip failed: \(error)")
            }

            // JSON written before this field existed — a real Note payload with
            // "calendarEventSnapshot" stripped out — should still decode, with
            // the field nil.
            do {
                var legacyNote = Note(title: "Pre-snapshot note")
                legacyNote.calendarEventUID = "legacy@google.com"
                let data = try encoder.encode(legacyNote)
                guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.coderInvalidValue)
                }
                object.removeValue(forKey: "calendarEventSnapshot")
                let legacy = try JSONSerialization.data(withJSONObject: object)
                let decoded = try decoder.decode(Note.self, from: legacy)
                expect(decoded.title == "Pre-snapshot note", "legacy note title decodes")
                expect(decoded.calendarEventUID == "legacy@google.com", "legacy note's other fields decode")
                expect(decoded.calendarEventSnapshot == nil, "legacy note decodes with a nil snapshot")
            } catch {
                expect(false, "legacy note decode failed: \(error)")
            }
        }

        expect(CalendarEvent.placeholder(for: Note(title: "No link")) == nil, "placeholder is nil without a calendar link")
        do {
            var linked = Note(title: "Standalone")
            linked.calendarEventUID = "placeholder@google.com"
            linked.calendarEventInstanceStart = Date(timeIntervalSince1970: 1_787_259_600)
            linked.calendarHTMLLink = "https://calendar.google.com/event?eid=xyz"
            let placeholder = CalendarEvent.placeholder(for: linked)
            expect(placeholder?.title == "Standalone", "placeholder title comes from the note")
            expect(placeholder?.googleCalendarURL?.absoluteString == "https://calendar.google.com/event?eid=xyz", "placeholder carries the Google Calendar link")
        }

        do {
            let renamed = event(identity: meeting.identity, calendarID: meeting.calendarID, title: "Interview (rescheduled)")
            store.refreshCalendarSnapshots(from: [renamed])
            expect(store.note(id: replacement.id)?.calendarEventSnapshot?.displayTitle == "Interview (rescheduled)", "live refresh updates a matching note's snapshot")
            let unrelated = store.createNote(title: "Not linked to anything")
            store.refreshCalendarSnapshots(from: [renamed])
            expect(store.note(id: unrelated.id)?.calendarEventSnapshot == nil, "refresh leaves unrelated notes untouched")
        }

        // OAuth client JSON. The shape Google actually hands you is nested under
        // "installed"; a flat object with the same fields is also accepted.
        func parsed(_ json: String, _ message: String) -> GoogleCalendarAuth.Credentials? {
            do {
                return try GoogleCalendarAuth.parseClientJSON(Data(json.utf8))
            } catch {
                expect(false, "\(message): \(error.localizedDescription)")
                return nil
            }
        }
        func rejects(_ json: String, _ message: String) {
            if (try? GoogleCalendarAuth.parseClientJSON(Data(json.utf8))) != nil {
                expect(false, message)
            }
        }

        let installed = parsed(
            #"{"installed":{"client_id":"123.apps.googleusercontent.com","client_secret":"shh","redirect_uris":["http://localhost"]}}"#,
            "desktop client JSON should parse"
        )
        expect(installed?.clientID == "123.apps.googleusercontent.com", "installed client_id")
        expect(installed?.clientSecret == "shh", "installed client_secret")

        let web = parsed(
            #"{"web":{"client_id":"456.apps.googleusercontent.com","client_secret":"psst"}}"#,
            "web client JSON should parse"
        )
        expect(web?.clientID == "456.apps.googleusercontent.com", "web client_id")

        let flat = parsed(
            #"{"client_id":"  789.apps.googleusercontent.com  ","client_secret":"  x  "}"#,
            "flat client JSON should parse"
        )
        expect(flat?.clientID == "789.apps.googleusercontent.com", "client_id is trimmed")
        expect(flat?.clientSecret == "x", "client_secret is trimmed")

        let noSecret = parsed(#"{"installed":{"client_id":"abc.apps.googleusercontent.com"}}"#,
                              "client without a secret should parse")
        expect(noSecret?.clientSecret == nil, "absent client_secret stays nil")
        let blankSecret = parsed(#"{"client_id":"abc.apps.googleusercontent.com","client_secret":"   "}"#,
                                 "blank secret should parse")
        expect(blankSecret?.clientSecret == nil, "whitespace-only client_secret is treated as absent")

        rejects(#"{"installed":{"client_secret":"shh"}}"#, "missing client_id should be rejected")
        rejects(#"{"client_id":"   "}"#, "blank client_id should be rejected")
        rejects("not json at all", "malformed JSON should be rejected")
        rejects(
            #"{"client_id":"YOUR_DESKTOP_OAUTH_CLIENT_ID.apps.googleusercontent.com"}"#,
            "the .example placeholder should be rejected"
        )

        // Dosa is ad-hoc signed, so a keychain read can cost an access prompt.
        // `clientID` and `hasCredentials` are read on every render of the Settings
        // section; if either reaches the keychain the user gets a prompt storm.
        // Keep them on UserDefaults.
        let defaults = UserDefaults.standard
        let savedClientID = defaults.string(forKey: AppSettings.googleCalendarClientIDKey)
        defaults.set("render-path-probe.apps.googleusercontent.com", forKey: AppSettings.googleCalendarClientIDKey)
        expect(GoogleCalendarAuth.clientID == "render-path-probe.apps.googleusercontent.com",
               "clientID should read straight from UserDefaults")
        defaults.removeObject(forKey: AppSettings.googleCalendarClientIDKey)
        expect(GoogleCalendarAuth.clientID == nil, "clearing the default clears the client ID")
        if let savedClientID {
            defaults.set(savedClientID, forKey: AppSettings.googleCalendarClientIDKey)
        }

        return failures
    }
}

private func attendee(email: String = "me@example.com", isSelf: Bool = false, isResource: Bool = false) -> CalendarAttendee {
    CalendarAttendee(email: email, displayName: email, isSelf: isSelf, isResource: isResource, responseStatus: "accepted")
}

private func event(
    identity: CalendarEventIdentity? = nil,
    calendarID: String = "me@example.com",
    calendarName: String = "Personal",
    title: String = "Meeting",
    attendees: [CalendarAttendee] = []
) -> CalendarEvent {
    let start = identity?.instanceStart ?? Date(timeIntervalSince1970: 1_787_259_600)
    return CalendarEvent(
        identity: identity ?? CalendarEventIdentity(iCalUID: UUID().uuidString, instanceStart: start),
        googleEventID: UUID().uuidString,
        calendarID: calendarID,
        calendarName: calendarName,
        title: title,
        start: start,
        end: start.addingTimeInterval(1800),
        isAllDay: false,
        timeZoneIdentifier: "America/Los_Angeles",
        status: "confirmed",
        selfResponseStatus: attendees.first(where: \.isSelf)?.responseStatus,
        attendees: attendees,
        location: nil,
        descriptionHTML: nil,
        googleCalendarURL: URL(string: "https://calendar.google.com/event?eid=abc"),
        meetingLinks: [],
        eventType: "default"
    )
}
