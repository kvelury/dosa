import Foundation
import SwiftUI

/// App-facing Notion integration: connection lifecycle, the auto-created
/// "Dosa Notes" database, and note export via Notion's hosted MCP tools.
@MainActor
final class NotionManager: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(workspace: String)
    }

    struct Destination: Equatable {
        let type: String   // "page" or "data_source"
        let id: String
        let title: String
    }

    struct DataSourceOption: Identifiable, Equatable {
        let id: String
        let name: String
    }

    static let databaseTitle = "Dosa Notes"

    @Published var connectionState: ConnectionState = .disconnected
    @Published var destination: Destination?
    @Published var exportingNoteId: UUID?
    @Published var settingUpDatabase = false
    @Published var errorMessage: String?
    @Published var errorDetail: String?

    private let auth = NotionAuth()
    private let client = NotionMCPClient()
    private var connectTask: Task<Void, Never>?

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var canExport: Bool {
        isConnected
    }

    var databaseURL: URL? {
        UserDefaults.standard.string(forKey: AppSettings.notionDatabaseURLKey).flatMap(URL.init(string:))
    }

    init() {
        let defaults = UserDefaults.standard
        if auth.isConnected {
            connectionState = .connected(workspace: defaults.string(forKey: AppSettings.notionWorkspaceKey) ?? "Notion")
        }
        if let type = defaults.string(forKey: AppSettings.notionDestTypeKey),
           let id = defaults.string(forKey: AppSettings.notionDestIdKey) {
            destination = Destination(
                type: type,
                id: id,
                title: defaults.string(forKey: AppSettings.notionDestTitleKey) ?? Self.databaseTitle
            )
        }
    }

    // MARK: - Connection

    func connect() {
        guard case .disconnected = connectionState else { return }
        connectionState = .connecting
        clearError()
        connectTask = Task {
            do {
                try await auth.authorize()
                client.reset()
                let workspace = (try? await fetchWorkspaceName()) ?? "Notion"
                UserDefaults.standard.set(workspace, forKey: AppSettings.notionWorkspaceKey)
                connectionState = .connected(workspace: workspace)
                // First-time setup: create the Dosa Notes database right away.
                if destination == nil {
                    await setUpDatabase()
                }
            } catch NotionAuth.AuthError.cancelled {
                connectionState = .disconnected
            } catch {
                setError(error)
                connectionState = .disconnected
            }
        }
    }

    func cancelConnect() {
        auth.cancelAuthorization()
        connectTask?.cancel()
        connectionState = .disconnected
    }

    func disconnect() {
        auth.clear()
        client.reset()
        setDestination(nil)
        UserDefaults.standard.removeObject(forKey: AppSettings.notionDatabaseURLKey)
        connectionState = .disconnected
        clearError()
    }

    // MARK: - Dosa Notes database

    /// Creates the "Dosa Notes" database (Title + Date) if it isn't set up yet.
    func setUpDatabase() async {
        guard !settingUpDatabase else { return }
        settingUpDatabase = true
        defer { settingUpDatabase = false }
        do {
            _ = try await ensureDatabase()
            clearError()
        } catch {
            setError(error)
        }
    }

    private func ensureDatabase() async throws -> Destination {
        if let destination {
            return destination
        }
        let text = try await callToolAuthorized("notion-create-database", [
            "title": Self.databaseTitle,
            "description": "Meeting notes exported from Dosa.",
            "schema": #"CREATE TABLE ("Title" TITLE, "Date" DATE)"#,
        ])
        guard let source = Self.parseDataSources(from: text).first else {
            throw NotionMCPClient.ClientError.malformed("created database did not include a data source ID")
        }
        if let (url, _) = Self.firstNotionPage(in: text) {
            UserDefaults.standard.set(url, forKey: AppSettings.notionDatabaseURLKey)
        }
        UserDefaults.standard.set("Title", forKey: AppSettings.notionTitlePropertyKey)
        let newDestination = Destination(type: "data_source", id: source.id, title: Self.databaseTitle)
        setDestination(newDestination)
        return newDestination
    }

    private func setDestination(_ newDestination: Destination?) {
        destination = newDestination
        let defaults = UserDefaults.standard
        if let newDestination {
            defaults.set(newDestination.type, forKey: AppSettings.notionDestTypeKey)
            defaults.set(newDestination.id, forKey: AppSettings.notionDestIdKey)
            defaults.set(newDestination.title, forKey: AppSettings.notionDestTitleKey)
        } else {
            defaults.removeObject(forKey: AppSettings.notionDestTypeKey)
            defaults.removeObject(forKey: AppSettings.notionDestIdKey)
            defaults.removeObject(forKey: AppSettings.notionDestTitleKey)
            defaults.removeObject(forKey: AppSettings.notionTitlePropertyKey)
        }
    }

    // MARK: - Export

    /// Exports the note into the Dosa Notes database, creating the database on
    /// first use. First export creates the page and remembers it on the note;
    /// later exports update it in place. Returns true on success.
    func export(note: Note, store: NotesStore) async -> Bool {
        guard exportingNoteId == nil else { return false }
        exportingNoteId = note.id
        defer { exportingNoteId = nil }
        clearError()

        let content = """
        *\(note.createdAt.formatted(date: .long, time: .omitted))*

        \(note.enhancedMarkdown ?? note.manualText)
        """

        do {
            if let pageId = note.notionPageId {
                do {
                    try await updatePage(pageId: pageId, title: note.displayTitle, content: content)
                    return true
                } catch let error as NotionMCPClient.ClientError {
                    guard case .tool(let message) = error, Self.looksLikeMissingPage(message) else { throw error }
                    // The page was deleted/archived in Notion — create a fresh one.
                    store.setNotionPage(noteId: note.id, pageId: nil, pageURL: nil)
                }
            }

            var target = try await ensureDatabase()
            do {
                let (newPageId, newPageURL) = try await createPage(destination: target, note: note, content: content)
                store.setNotionPage(noteId: note.id, pageId: newPageId, pageURL: newPageURL)
            } catch let error as NotionMCPClient.ClientError {
                guard case .tool(let message) = error, Self.looksLikeMissingPage(message) else { throw error }
                // The Dosa Notes database itself was deleted — recreate and retry once.
                setDestination(nil)
                target = try await ensureDatabase()
                let (newPageId, newPageURL) = try await createPage(destination: target, note: note, content: content)
                store.setNotionPage(noteId: note.id, pageId: newPageId, pageURL: newPageURL)
            }
            return true
        } catch {
            setError(error)
            return false
        }
    }

    private func createPage(destination: Destination, note: Note, content: String) async throws -> (String, String?) {
        let parent: [String: Any] = destination.type == "page"
            ? ["type": "page_id", "page_id": destination.id]
            : ["type": "data_source_id", "data_source_id": destination.id]

        let titleProperty = UserDefaults.standard.string(forKey: AppSettings.notionTitlePropertyKey) ?? "Title"
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: note.createdAt)

        // Preferred properties first; drop the pieces the schema rejects.
        let propertyAttempts: [[String: Any]] = [
            [titleProperty: note.displayTitle, "date:Date:start": dateString, "date:Date:is_datetime": 0],
            [titleProperty: note.displayTitle],
            ["title": note.displayTitle],
            ["Name": note.displayTitle],
        ]

        var lastError: Error = NotionMCPClient.ClientError.malformed("page creation failed")
        for (index, properties) in propertyAttempts.enumerated() {
            do {
                let text = try await callToolAuthorized("notion-create-pages", [
                    "parent": parent,
                    "pages": [["properties": properties, "content": content]],
                ])
                guard let (url, id) = Self.firstNotionPage(in: text) else {
                    throw NotionMCPClient.ClientError.malformed("created page reference not found in: \(String(text.prefix(500)))")
                }
                return (id, url)
            } catch let error as NotionMCPClient.ClientError {
                guard case .tool(let message) = error else { throw error }
                if Self.looksLikeMissingPage(message) || index == propertyAttempts.count - 1 {
                    throw error
                }
                lastError = error
            }
        }
        throw lastError
    }

    private func updatePage(pageId: String, title: String, content: String) async throws {
        _ = try await callToolAuthorized("notion-update-page", [
            "page_id": pageId,
            "command": "replace_content",
            "new_str": content,
            "allow_deleting_content": true,
        ])
        let titleProperty = UserDefaults.standard.string(forKey: AppSettings.notionTitlePropertyKey) ?? "Title"
        _ = try? await callToolAuthorized("notion-update-page", [
            "page_id": pageId,
            "command": "update_properties",
            "properties": [titleProperty: title],
        ])
    }

    // MARK: - Plumbing

    private func setError(_ error: Error) {
        errorMessage = error.localizedDescription
        errorDetail = (error as? DetailedError)?.errorDetail
    }

    private func clearError() {
        errorMessage = nil
        errorDetail = nil
    }

    private func callToolAuthorized(_ name: String, _ arguments: [String: Any]) async throws -> String {
        let token = try await auth.validAccessToken()
        do {
            return try await client.callTool(name: name, arguments: arguments, accessToken: token)
        } catch NotionMCPClient.ClientError.unauthorized {
            let refreshed = try await auth.refreshAccessToken()
            client.reset()
            return try await client.callTool(name: name, arguments: arguments, accessToken: refreshed)
        }
    }

    private func fetchWorkspaceName() async throws -> String? {
        let text = try await callToolAuthorized("notion-fetch", ["id": "self"])
        if let workspaceRange = text.range(of: "workspace", options: .caseInsensitive) {
            let tail = String(text[workspaceRange.upperBound...])
            if let match = tail.range(of: #""name"\s*:\s*"([^"]+)""#, options: .regularExpression) {
                let fragment = String(tail[match])
                if let nameMatch = fragment.range(of: #":\s*"([^"]+)""#, options: .regularExpression) {
                    return String(fragment[nameMatch])
                        .replacingOccurrences(of: #"^:\s*""#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: "\"", with: "")
                }
            }
        }
        return nil
    }

    // MARK: - Response parsing (tolerant by design: the MCP tools return
    // markdown/tagged text meant for language models, not a fixed schema)

    static func parseDataSources(from text: String) -> [DataSourceOption] {
        var options: [DataSourceOption] = []
        var seen = Set<String>()
        let tagPattern = try! NSRegularExpression(pattern: #"<data-source[^>]*>"#)
        let ns = text as NSString
        for match in tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let idRange = tag.range(of: #"collection://([0-9a-fA-F-]{32,36})"#, options: .regularExpression) else { continue }
            let id = String(tag[idRange]).replacingOccurrences(of: "collection://", with: "")
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            var name = ""
            if let nameRange = tag.range(of: #"name="([^"]*)""#, options: .regularExpression) {
                name = String(tag[nameRange])
                    .replacingOccurrences(of: "name=", with: "")
                    .replacingOccurrences(of: "\"", with: "")
            }
            options.append(DataSourceOption(id: id, name: name.isEmpty ? "Data source \(options.count + 1)" : name))
        }
        if options.isEmpty {
            let bare = try! NSRegularExpression(pattern: #"collection://([0-9a-fA-F-]{32,36})"#)
            for match in bare.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let id = ns.substring(with: match.range(at: 1))
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                options.append(DataSourceOption(id: id, name: "Data source \(options.count + 1)"))
            }
        }
        return options
    }

    static func firstNotionPage(in text: String) -> (url: String, id: String)? {
        let pattern = try! NSRegularExpression(pattern: #"https://(?:www\.notion\.so|app\.notion\.com)/[^\s\)\"'<>\]]+"#)
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let url = ns.substring(with: match.range)
            if let id = notionId(fromURL: url) {
                return (url, id)
            }
        }
        // Some results reference pages by bare UUID rather than URL.
        if let idRange = text.range(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#, options: .regularExpression) {
            let id = String(text[idRange])
            return ("https://www.notion.so/\(id.replacingOccurrences(of: "-", with: ""))", id)
        }
        return nil
    }

    static func notionId(fromURL url: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"[0-9a-fA-F]{32}"#)
        let ns = url.components(separatedBy: "?").first.map { $0 as NSString } ?? (url as NSString)
        let matches = pattern.matches(in: ns as String, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        return ns.substring(with: last.range)
    }

    private static func looksLikeMissingPage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("not found") || lowered.contains("could not find")
            || lowered.contains("archived") || lowered.contains("deleted")
            || lowered.contains("no access") || lowered.contains("does not exist")
    }
}
