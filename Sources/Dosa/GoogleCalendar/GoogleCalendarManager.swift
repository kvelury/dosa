import Foundation
import AppKit
import SwiftUI

@MainActor
final class GoogleCalendarManager: ObservableObject {
    enum ConnectionState: Equatable {
        case unavailable
        case disconnected
        case connecting
        case connected(account: String)
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var calendars: [CalendarInfo] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var events: [CalendarEvent] = []
    @Published var isRefreshing = false
    @Published var lastSuccessfulSyncAt: Date?
    @Published var errorMessage: String?
    @Published var errorDetail: String?
    @Published var partialFailureMessage: String?
    @Published var showSetupBanner = false

    private let auth = GoogleCalendarAuth()
    private let client = GoogleCalendarClient()
    private var connectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var hourlyTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var started = false
    private var firstSessionHadCredentials = false

    private var cacheURL: URL {
        CalendarCache.fileURL(in: NotesStore.applicationSupportDirectory)
    }

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var hasCredentials: Bool { auth.hasCredentials }

    var isStale: Bool {
        guard isConnected else { return false }
        guard let lastSuccessfulSyncAt else { return true }
        return Date().timeIntervalSince(lastSuccessfulSyncAt) >= 3600
    }

    var upcomingMeetings: [CalendarEvent] {
        let now = Date()
        return events.filter { $0.end > now }
    }

    init() {
        if !auth.hasCredentials {
            connectionState = .unavailable
        } else if auth.isConnected {
            let account = UserDefaults.standard.string(forKey: AppSettings.googleCalendarAccountKey) ?? "Google"
            connectionState = .connected(account: account)
            loadPersistedSelection()
            loadCache()
        } else {
            connectionState = .disconnected
        }
        updateBannerVisibility()
    }

    func start() {
        guard !started else { return }
        started = true
        firstSessionHadCredentials = auth.hasCredentials
        if isConnected {
            Task { await refresh() }
        }
        hourlyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refreshIfStale()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if self?.isStale == true { await self?.refresh() }
            }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                if self?.isStale == true { await self?.refresh() }
            }
        }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.markOnboardingFinishedIfEligible()
        }
    }

    func connect() {
        guard hasCredentials else {
            connectionState = .unavailable
            errorMessage = GoogleCalendarAuth.AuthError.credentialsMissing.errorDescription
            return
        }
        guard case .disconnected = connectionState else { return }
        connectionState = .connecting
        clearError()
        connectTask = Task {
            do {
                try await auth.authorize()
                let listed = try await fetchCalendars()
                calendars = listed
                if selectedCalendarIDs.isEmpty {
                    if let primary = listed.first(where: \.isPrimary) ?? listed.first {
                        selectedCalendarIDs = [primary.id]
                        persistSelection()
                    }
                } else {
                    selectedCalendarIDs = selectedCalendarIDs.intersection(Set(listed.map(\.id)))
                    if selectedCalendarIDs.isEmpty, let primary = listed.first(where: \.isPrimary) ?? listed.first {
                        selectedCalendarIDs = [primary.id]
                    }
                    persistSelection()
                }
                let account = listed.first(where: \.isPrimary)?.id ?? listed.first?.id ?? "Google"
                UserDefaults.standard.set(account, forKey: AppSettings.googleCalendarAccountKey)
                connectionState = .connected(account: account)
                finishOnboarding()
                await refresh()
            } catch GoogleCalendarAuth.AuthError.cancelled {
                connectionState = .disconnected
            } catch {
                setError(error)
                connectionState = .disconnected
            }
            updateBannerVisibility()
        }
    }

    func cancelConnect() {
        auth.cancelAuthorization()
        connectTask?.cancel()
        connectionState = hasCredentials ? .disconnected : .unavailable
        updateBannerVisibility()
    }

    func disconnect() {
        auth.clear()
        calendars = []
        selectedCalendarIDs = []
        events = []
        lastSuccessfulSyncAt = nil
        persistSelection()
        UserDefaults.standard.removeObject(forKey: AppSettings.googleCalendarAccountKey)
        CalendarCache.remove(at: cacheURL)
        connectionState = hasCredentials ? .disconnected : .unavailable
        clearError()
        updateBannerVisibility()
    }

    func dismissSetupBanner() {
        finishOnboarding()
        updateBannerVisibility()
    }

    func setCalendarSelected(_ id: String, selected: Bool) {
        guard isConnected else { return }
        var next = selectedCalendarIDs
        if selected {
            next.insert(id)
        } else {
            next.remove(id)
            if next.isEmpty { return }
        }
        selectedCalendarIDs = next
        persistSelection()
        Task { await refresh() }
    }

    func refresh() async {
        guard isConnected else { return }
        guard refreshTask == nil else { return }
        refreshTask = Task { await performRefresh() }
        await refreshTask?.value
        refreshTask = nil
    }

    func refreshIfStale() async {
        if isStale { await refresh() }
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            var token = try await validToken()
            let listed: [CalendarInfo]
            do {
                listed = try await client.listCalendars(accessToken: token)
            } catch GoogleCalendarClient.ClientError.unauthorized {
                token = try await auth.refreshAccessToken()
                listed = try await client.listCalendars(accessToken: token)
            }
            calendars = listed
            selectedCalendarIDs = selectedCalendarIDs.intersection(Set(listed.map(\.id)))
            if selectedCalendarIDs.isEmpty, let primary = listed.first(where: \.isPrimary) ?? listed.first {
                selectedCalendarIDs = [primary.id]
            }
            persistSelection()

            let window = CalendarSyncWindow.bounds(now: Date(), calendar: Foundation.Calendar.current)
            let selected = listed.filter { selectedCalendarIDs.contains($0.id) }
            var freshByCalendar: [String: [CalendarEvent]] = [:]
            var failed: [String] = []
            var sawUnauthorized = false
            let accessToken = token

            await withTaskGroup(of: (String, Result<[CalendarEvent], Error>).self) { group in
                let client = self.client
                var queued = 0
                var index = 0
                func enqueueAvailable() {
                    while queued < 4, index < selected.count {
                        let calendar = selected[index]
                        index += 1
                        queued += 1
                        group.addTask {
                            do {
                                let events = try await client.listEvents(
                                    calendar: calendar,
                                    timeMin: window.start,
                                    timeMax: window.end,
                                    accessToken: accessToken
                                )
                                return (calendar.id, .success(events))
                            } catch {
                                return (calendar.id, .failure(error))
                            }
                        }
                    }
                }
                enqueueAvailable()
                while let result = await group.next() {
                    queued -= 1
                    switch result.1 {
                    case .success(let calendarEvents):
                        freshByCalendar[result.0] = calendarEvents
                    case .failure(let error):
                        if let clientError = error as? GoogleCalendarClient.ClientError,
                           case .unauthorized = clientError {
                            sawUnauthorized = true
                        }
                        failed.append(result.0)
                    }
                    enqueueAvailable()
                }
            }

            if sawUnauthorized {
                token = try await auth.refreshAccessToken()
                freshByCalendar.removeAll()
                failed.removeAll()
                for calendar in selected {
                    do {
                        freshByCalendar[calendar.id] = try await client.listEvents(
                            calendar: calendar,
                            timeMin: window.start,
                            timeMax: window.end,
                            accessToken: token
                        )
                    } catch {
                        failed.append(calendar.id)
                    }
                }
            }

            if freshByCalendar.isEmpty, !selected.isEmpty {
                events = CalendarSyncReducer.eventsAfterFailedRefresh(current: events)
                if sawUnauthorized, failed.count == selected.count {
                    setError(GoogleCalendarAuth.AuthError.notConnected)
                    disconnectPreservingOnboarding()
                    return
                }
                if let firstFailure = failed.first,
                   let name = listed.first(where: { $0.id == firstFailure })?.name {
                    errorMessage = "Couldn’t refresh Google Calendar (\(name)). Showing the last saved meetings."
                } else {
                    errorMessage = "Couldn’t refresh Google Calendar. Showing the last saved meetings."
                }
                partialFailureMessage = nil
                return
            }

            let merged = CalendarSyncReducer.merge(
                cached: events,
                freshByCalendar: freshByCalendar,
                failedCalendarIDs: Set(failed)
            )
            let preferred = preferredCalendarOrder(listed)
            events = CalendarEventDeduper.dedupe(
                merged.filter(CalendarMeetingFilter.isMeeting),
                preferredCalendarIDs: preferred
            )
            lastSuccessfulSyncAt = Date()
            if failed.isEmpty {
                clearError()
                partialFailureMessage = nil
            } else {
                errorMessage = nil
                let names = failed.compactMap { id in listed.first(where: { $0.id == id })?.name ?? id }
                partialFailureMessage = "Couldn’t refresh \(names.joined(separator: ", ")). Other calendars are up to date."
            }
            saveCache(account: UserDefaults.standard.string(forKey: AppSettings.googleCalendarAccountKey))
        } catch GoogleCalendarClient.ClientError.unauthorized {
            setError(GoogleCalendarAuth.AuthError.notConnected)
            disconnectPreservingOnboarding()
        } catch {
            events = CalendarSyncReducer.eventsAfterFailedRefresh(current: events)
            setError(error)
            partialFailureMessage = nil
        }
    }

    private func fetchCalendars() async throws -> [CalendarInfo] {
        let token = try await validToken()
        return try await client.listCalendars(accessToken: token)
    }

    private func validToken() async throws -> String {
        do {
            return try await auth.validAccessToken()
        } catch GoogleCalendarClient.ClientError.unauthorized {
            return try await auth.refreshAccessToken()
        }
    }

    private func preferredCalendarOrder(_ listed: [CalendarInfo]) -> [String] {
        let primary = listed.first(where: \.isPrimary).map { [$0.id] } ?? []
        let rest = listed.map(\.id).filter { !primary.contains($0) }
        return primary + rest
    }

    private func loadCache() {
        guard let snapshot = CalendarCache.load(from: cacheURL) else { return }
        if calendars.isEmpty { calendars = snapshot.calendars }
        if selectedCalendarIDs.isEmpty { selectedCalendarIDs = Set(snapshot.selectedCalendarIDs) }
        events = snapshot.events.filter(CalendarMeetingFilter.isMeeting)
        lastSuccessfulSyncAt = snapshot.lastSuccessfulSyncAt
        if !snapshot.failedCalendarIDs.isEmpty {
            partialFailureMessage = "Some calendars didn’t refresh last time. Showing saved meetings."
        }
    }

    private func saveCache(account: String?) {
        let snapshot = CalendarCacheSnapshot(
            accountEmail: account,
            calendars: calendars,
            selectedCalendarIDs: Array(selectedCalendarIDs),
            events: events,
            lastSuccessfulSyncAt: lastSuccessfulSyncAt,
            failedCalendarIDs: []
        )
        CalendarCache.save(snapshot, to: cacheURL)
    }

    private func loadPersistedSelection() {
        if let ids = UserDefaults.standard.array(forKey: AppSettings.googleCalendarSelectedIDsKey) as? [String] {
            selectedCalendarIDs = Set(ids)
        }
    }

    private func persistSelection() {
        UserDefaults.standard.set(Array(selectedCalendarIDs), forKey: AppSettings.googleCalendarSelectedIDsKey)
    }

    private func disconnectPreservingOnboarding() {
        auth.clear()
        calendars = []
        selectedCalendarIDs = []
        persistSelection()
        UserDefaults.standard.removeObject(forKey: AppSettings.googleCalendarAccountKey)
        CalendarCache.remove(at: cacheURL)
        connectionState = hasCredentials ? .disconnected : .unavailable
        updateBannerVisibility()
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: AppSettings.googleCalendarOnboardingFinishedKey)
        showSetupBanner = false
    }

    private func markOnboardingFinishedIfEligible() {
        let finished = UserDefaults.standard.bool(forKey: AppSettings.googleCalendarOnboardingFinishedKey)
        if !finished, firstSessionHadCredentials {
            UserDefaults.standard.set(true, forKey: AppSettings.googleCalendarOnboardingFinishedKey)
        }
    }

    private func updateBannerVisibility() {
        let finished = UserDefaults.standard.bool(forKey: AppSettings.googleCalendarOnboardingFinishedKey)
        showSetupBanner = !finished && hasCredentials && !isConnected && connectionState != .connecting
    }

    private func setError(_ error: Error) {
        errorMessage = error.localizedDescription
        errorDetail = (error as? DetailedError)?.errorDetail
    }

    private func clearError() {
        errorMessage = nil
        errorDetail = nil
    }
}
