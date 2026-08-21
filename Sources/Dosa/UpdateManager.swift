import AppKit
import CryptoKit
import Foundation

enum BuildInfo {
    static let shortVersion  = info("CFBundleShortVersionString") ?? "1.6"
    static let bundleVersion = info("CFBundleVersion") ?? "0"
    static let commit        = info("DosaBuildCommit") ?? ""
    static var shortCommit: String { String(commit.prefix(7)) }
    static let commitDate    = info("DosaBuildDate")
    static let isReleaseBuild = info("DosaBuildChannel") == "release"
    static let isDirty = Bundle.main.object(forInfoDictionaryKey: "DosaBuildDirty") as? Bool ?? false

    /// The repo root when this bundle is `<repo>/build/Dosa.app` — installing here
    /// overwrites build output, so the confirmation has to say so.
    ///
    /// `.git` is checked with fileExists and not isDirectory on purpose: in a git
    /// *worktree* it is a file holding a `gitdir:` pointer, not a directory.
    static var repoCheckoutRoot: URL? {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        guard parent.lastPathComponent == "build" else { return nil }
        let root = parent.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
            ? root : nil
    }

    private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

enum UpdateError: LocalizedError, DetailedError {
    case http(Int, String)
    case noRelease
    case rateLimited(Date?)
    case malformedManifest(String)
    case incompatibleArchitecture(String)
    case destinationNotWritable(URL)
    case unpackFailed(String)
    case verificationFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case busy([String])

    var errorDescription: String? {
        switch self {
        case .http(let status, _):
            return "The update check failed (HTTP \(status))."
        case .noRelease:
            return "No release has been published yet."
        case .rateLimited(let reset):
            if let reset {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                formatter.dateStyle = Calendar.current.isDateInToday(reset) ? .none : .medium
                return "GitHub is rate-limiting update checks from this network. Try again after \(formatter.string(from: reset))."
            }
            return "GitHub is rate-limiting update checks from this network. Try again later."
        case .malformedManifest:
            return "The update's manifest was unreadable, so Dosa didn't install it."
        case .incompatibleArchitecture:
            return "This update isn't built for this Mac's processor. Download a matching build from the Releases page."
        case .destinationNotWritable:
            return "Dosa can't update itself here."
        case .unpackFailed:
            return "The update downloaded but couldn't be unpacked."
        case .verificationFailed:
            return "The downloaded update didn't pass verification, so it wasn't installed."
        case .checksumMismatch:
            return "The downloaded update didn't match its checksum, so it wasn't installed."
        case .busy(let work):
            return "Dosa is \(work.joined(separator: " and ")) — finish that before installing."
        }
    }

    var errorDetail: String? {
        switch self {
        case .http(_, let body), .malformedManifest(let body), .unpackFailed(let body),
             .verificationFailed(let body), .incompatibleArchitecture(let body):
            return body.isEmpty ? nil : String(body.prefix(4000))
        case .checksumMismatch(let expected, let actual):
            return "expected \(expected)\nactual   \(actual)"
        case .destinationNotWritable(let url):
            return url.path
        case .noRelease, .rateLimited, .busy:
            return nil
        }
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    static let repo = "kvelury/dosa"
    static let releasesPageURL = URL(string: "https://github.com/\(repo)/releases")!

    struct Update: Equatable {
        let commit, shortCommit, tag, shortVersion: String
        let commitDate: Date?
        let zipURL: URL
        let sha256: String
        let arch: [String]
        let minimumSystemVersion: String
        let releaseURL: URL
        var commitCount = 0
        var subjects: [String] = []      // first lines only, capped at 5
        var compareURL: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Update)
        case downloading(Double)         // 0…1
        case verifying
        case readyToInstall(Update)      // staged on disk and verified
        case installing                  // helper spawned, app is quitting
    }

    @Published private(set) var state: State = .idle
    /// Survives state churn; this is what drives the sidebar badge.
    @Published private(set) var available: Update?
    /// e.g. "Your build is ahead of the latest release." Not an error.
    @Published private(set) var statusNote: String?
    @Published var errorMessage: String?
    @Published var errorDetail: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var destinationWritable = true
    @Published private(set) var downloadReceivedBytes: Int64 = 0
    @Published private(set) var downloadExpectedBytes: Int64 = 0
    /// Text from a previous helper-script failure, shown in the Settings footer.
    @Published private(set) var previousFailure: String?

    private var currentTask: Task<Void, Never>?
    private var stagedApp: URL?
    private var stagingDir: URL?
    private var hasCheckedThisLaunch = false
    /// Retained so Foundation.Process cannot terminate the helper in deinit
    /// while this process is quitting.
    private static var retainedHelper: Process?

    private static let throttleInterval: TimeInterval = 4 * 60 * 60
    private static let progressChunk = 256 * 1024

    func checkOnLaunch() async {
        consumePreviousFailure()
        guard !hasCheckedThisLaunch else { return }
        hasCheckedThisLaunch = true
        guard AppSettings.automaticUpdateCheckEnabled else { return }
        let last = UserDefaults.standard.double(forKey: AppSettings.lastUpdateCheckKey)
        if last > 0, Date.timeIntervalSinceReferenceDate - last < Self.throttleInterval {
            return
        }
        await performCheck(manual: false)
    }

    func check(manual: Bool = true) {
        if case .installing = state { return }
        hasCheckedThisLaunch = true
        currentTask?.cancel()
        currentTask = Task {
            await performCheck(manual: manual)
        }
    }

    func downloadAndStage() {
        guard case .available(let update) = state else { return }
        guard destinationWritable else {
            setError(UpdateError.destinationNotWritable(Bundle.main.bundleURL))
            return
        }
        currentTask?.cancel()
        currentTask = Task {
            await performDownload(update)
        }
    }

    func installAndRelaunch(onProceed: @escaping () -> Void) {
        guard case .readyToInstall(let update) = state, let staged = stagedApp else { return }
        state = .installing
        do {
            try spawnHelper(staged: staged)
            onProceed()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        } catch {
            setError(error)
            state = .readyToInstall(update)
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        cleanupStaging()
        downloadReceivedBytes = 0
        downloadExpectedBytes = 0
        if let available {
            state = .available(available)
        } else {
            state = .idle
        }
    }

    func clearError() {
        errorMessage = nil
        errorDetail = nil
    }

    func consumePreviousFailure() {
        let marker = Self.supportDirectory.appendingPathComponent("update-failed.txt")
        guard let raw = try? String(contentsOf: marker, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: marker)
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        previousFailure = text
    }

    // MARK: - Check

    private func performCheck(manual: Bool) async {
        if Task.isCancelled { return }
        probeDestinationWritable()
        if manual { clearError() }
        statusNote = nil
        state = .checking

        do {
            let release = try await fetchLatestRelease()
            if tagMatchesRunningBuild(release.tagName) {
                markSuccessfulCheck()
                available = nil
                statusNote = "You're on the latest build."
                state = .upToDate
                return
            }

            let manifest = try await fetchManifest(from: release)
            guard let zipURL = zipURL(in: release, named: manifest.asset) else {
                throw UpdateError.malformedManifest("release has no \(manifest.asset) asset")
            }
            var update = Update(
                commit: manifest.commit,
                shortCommit: manifest.shortCommit,
                tag: release.tagName,
                shortVersion: manifest.shortVersion,
                commitDate: Self.parseISO8601(manifest.commitDate),
                zipURL: zipURL,
                sha256: manifest.sha256,
                arch: Self.architectureSlices(manifest.arch),
                minimumSystemVersion: manifest.minimumSystemVersion,
                releaseURL: URL(string: release.htmlUrl) ?? Self.releasesPageURL
            )

            if !Self.currentMachineCanRun(update.arch) {
                throw UpdateError.incompatibleArchitecture(update.arch.joined(separator: ", "))
            }

            if BuildInfo.commit.isEmpty {
                statusNote = "This build isn't stamped with a commit, so Dosa can't tell whether it's current."
                markSuccessfulCheck()
                available = update
                state = .available(update)
                return
            }

            if BuildInfo.commit == manifest.commit {
                markSuccessfulCheck()
                available = nil
                statusNote = "You're on the latest build."
                state = .upToDate
                return
            }

            switch try await compare(ours: BuildInfo.commit, theirs: manifest.commit) {
            case .ahead(let count, let subjects, let compareURL):
                update.commitCount = count
                update.subjects = subjects
                update.compareURL = compareURL
                markSuccessfulCheck()
                available = update
                state = .available(update)
            case .identical:
                markSuccessfulCheck()
                available = nil
                statusNote = "You're on the latest build."
                state = .upToDate
            case .behind:
                markSuccessfulCheck()
                available = nil
                statusNote = "Your build is ahead of the latest release."
                state = .idle
            case .diverged:
                markSuccessfulCheck()
                available = nil
                statusNote = "This build has diverged from the latest release."
                state = .idle
            case .notOnGitHub:
                markSuccessfulCheck()
                available = nil
                statusNote = "This build is from a commit that isn't on GitHub, so there's nothing to compare it to."
                state = .idle
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch UpdateError.noRelease {
            markSuccessfulCheck()
            available = nil
            state = .idle
            if manual {
                statusNote = "No release has been published yet."
            }
        } catch {
            available = nil
            state = .idle
            if manual {
                setError(error)
            }
        }
    }

    private func tagMatchesRunningBuild(_ tagName: String) -> Bool {
        let short = BuildInfo.shortCommit
        guard !short.isEmpty else { return false }
        return tagName.split(separator: "-").last.map(String.init) == short
    }

    // MARK: - Download / verify

    private func performDownload(_ update: Update) async {
        if Task.isCancelled { return }
        clearError()
        cleanupStaging()
        downloadReceivedBytes = 0
        downloadExpectedBytes = 0
        state = .downloading(0)

        do {
            let dest = Bundle.main.bundleURL
            let staging = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: dest,
                create: true
            )
            stagingDir = staging
            let zipURL = staging.appendingPathComponent("Dosa.app.zip")
            try await download(from: update.zipURL, to: zipURL)
            if Task.isCancelled {
                cleanupStaging()
                return
            }
            state = .verifying
            let staged = try verify(update: update, zip: zipURL, stagingDir: staging)
            stagedApp = staged
            state = .readyToInstall(update)
        } catch is CancellationError {
            cleanupStaging()
            if let available { state = .available(available) } else { state = .idle }
        } catch let error as URLError where error.code == .cancelled {
            cleanupStaging()
            if let available { state = .available(available) } else { state = .idle }
        } catch {
            cleanupStaging()
            setError(error)
            state = .idle
            if let available { state = .available(available) }
        }
    }

    private func download(from url: URL, to destination: URL) async throws {
        var request = githubRequest(url)
        request.timeoutInterval = 120
        // Drain off the main actor: URLSession.AsyncBytes yields UInt8, and
        // iterating ~3 MB of those on @MainActor would freeze Settings.
        try await Self.downloadZip(request, to: destination) { received, expected in
            self.downloadReceivedBytes = received
            self.downloadExpectedBytes = expected
            let progress = expected > 0 ? min(1, Double(received) / Double(expected)) : 0
            self.state = .downloading(progress)
        }
    }

    nonisolated private static func downloadZip(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @MainActor (Int64, Int64) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.http(0, "No HTTP response received.")
        }
        if !(200..<300).contains(http.statusCode) {
            if (http.statusCode == 403 || http.statusCode == 429),
               http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                    .flatMap(TimeInterval.init)
                    .map { Date(timeIntervalSince1970: $0) }
                throw UpdateError.rateLimited(reset)
            }
            throw UpdateError.http(http.statusCode, "")
        }
        let expected = response.expectedContentLength
        await progress(0, expected)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        var received: Int64 = 0
        var sincePublish = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                sincePublish += buffer.count
                buffer.removeAll(keepingCapacity: true)
                if sincePublish >= 256 * 1024 {
                    sincePublish = 0
                    await progress(received, expected)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        await progress(received, expected)
    }

    private func verify(update: Update, zip: URL, stagingDir: URL) throws -> URL {
        // First Process() in app code (the only other one in the repo is
        // Scripts/make_icon.swift, a build script). ditto, not unzip: unzip
        // mangles symlinks and drops the metadata `ditto -c -k` wrote in CI.
        let unpack = Process()
        unpack.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unpack.arguments = ["-x", "-k", zip.path, stagingDir.path]
        let unpackOut = Pipe()
        unpack.standardOutput = unpackOut
        unpack.standardError = unpackOut
        try unpack.run()
        unpack.waitUntilExit()
        if unpack.terminationStatus != 0 {
            let msg = String(data: unpackOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.unpackFailed(msg)
        }

        let apps = try FileManager.default.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "app" }
        guard apps.count == 1, let staged = apps.first else {
            throw UpdateError.verificationFailed("expected exactly one .app at the archive root, found \(apps.count)")
        }

        let digest = try sha256(of: zip)
        guard digest.caseInsensitiveCompare(update.sha256) == .orderedSame else {
            throw UpdateError.checksumMismatch(expected: update.sha256, actual: digest)
        }

        let infoURL = staged.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) else {
            throw UpdateError.verificationFailed("staged app has no Info.plist")
        }
        guard info["CFBundleIdentifier"] as? String == "com.dosa.meetingnotes" else {
            throw UpdateError.verificationFailed("bundle identifier is not com.dosa.meetingnotes")
        }
        let executable = info["CFBundleExecutable"] as? String ?? "Dosa"
        let execURL = staged.appendingPathComponent("Contents/MacOS/\(executable)")
        guard FileManager.default.isExecutableFile(atPath: execURL.path) else {
            throw UpdateError.verificationFailed("Contents/MacOS/\(executable) is missing or not executable")
        }
        guard (info["DosaBuildCommit"] as? String) == update.commit else {
            throw UpdateError.verificationFailed("staged DosaBuildCommit does not match the manifest")
        }
        guard Self.currentMachineCanRun(update.arch) else {
            throw UpdateError.incompatibleArchitecture(update.arch.joined(separator: ", "))
        }

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--strict", staged.path]
        let codesignOut = Pipe()
        codesign.standardOutput = codesignOut
        codesign.standardError = codesignOut
        try codesign.run()
        codesign.waitUntilExit()
        if codesign.terminationStatus != 0 {
            let msg = String(data: codesignOut.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.verificationFailed(msg)
        }

        if !Self.osAtLeast(update.minimumSystemVersion) {
            throw UpdateError.verificationFailed("this Mac is below the update's minimum system version (\(update.minimumSystemVersion))")
        }

        return staged
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: Self.progressChunk) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helper

    private func spawnHelper(staged: URL) throws {
        let dest = Bundle.main.bundleURL
        let backup = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(dest.lastPathComponent).bak")
        let support = Self.supportDirectory
        let marker = support.appendingPathComponent("update-failed.txt")
        let log = support.appendingPathComponent("update-helper.log")
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
        }

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dosa-update-\(UUID().uuidString).sh")
        try Self.helperScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let logHandle = try FileHandle(forWritingTo: log)
        _ = logHandle.seekToEndOfFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            "\(ProcessInfo.processInfo.processIdentifier)",
            staged.path,
            dest.path,
            backup.path,
            marker.path,
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Foundation.Process terminates its child in deinit. We are about to
        // quit, so retain the object for the rest of this process lifetime —
        // otherwise the helper would be killed on the way out and the swap
        // would never run.
        Self.retainedHelper = process
    }

    private static let helperScript = """
    #!/bin/sh
    # Dosa update helper. Args: <pid> <staged app> <destination> <backup> <marker>
    #
    # Runs detached from the app it is replacing: the swap must happen with no
    # process holding the bundle open, and it must still happen if Dosa crashes on
    # the way out — which is why it waits on the pid rather than being invoked last.
    set -u
    PID=$1; STAGED=$2; DEST=$3; BACKUP=$4; MARKER=$5

    # ps, not `kill -0`: pid reuse inside the wait window would otherwise wedge us.
    i=0
    while ps -p "$PID" -o comm= 2>/dev/null | grep -q Dosa; do
        i=$((i + 1))
        if [ "$i" -gt 300 ]; then
            printf 'Dosa (pid %s) did not quit within 30s; the update was not installed.\\n' "$PID" > "$MARKER"
            rm -rf "$STAGED"; exit 1
        fi
        sleep 0.1
    done

    # Ad-hoc signed and un-notarized: a quarantined copy would be refused at launch.
    /usr/bin/xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null

    rm -rf "$BACKUP"
    if ! /bin/mv "$DEST" "$BACKUP"; then
        printf 'Could not move %s aside — the update was not installed.\\n' "$DEST" > "$MARKER"
        rm -rf "$STAGED"; /usr/bin/open "$DEST"; exit 1
    fi
    if ! /bin/mv "$STAGED" "$DEST"; then
        /bin/mv "$BACKUP" "$DEST"                      # rollback
        printf 'Could not install the new version; the previous one was restored.\\n' > "$MARKER"
        rm -rf "$STAGED"; /usr/bin/open "$DEST"; exit 1
    fi
    rm -rf "$BACKUP"
    /usr/bin/open "$DEST"
    """

    // MARK: - GitHub

    private struct ReleaseDTO: Decodable {
        let tagName: String, htmlUrl: String, assets: [Asset]
        struct Asset: Decodable {
            let name: String, browserDownloadUrl: String, size: Int
            enum CodingKeys: String, CodingKey {
                case name, size
                case browserDownloadUrl = "browser_download_url"
            }
        }
        enum CodingKeys: String, CodingKey {
            case assets
            case tagName = "tag_name"
            case htmlUrl = "html_url"
        }
    }

    private struct ManifestDTO: Decodable {
        let schemaVersion: Int
        let commit, shortCommit, commitDate, shortVersion: String
        let bundleIdentifier, minimumSystemVersion, asset, sha256: String
        let arch: String            // comma-separated, from `lipo -archs`
    }

    private struct ComparisonDTO: Decodable {
        let status: String          // identical | ahead | behind | diverged
        let aheadBy: Int
        let htmlUrl: String
        let commits: [Commit]
        struct Commit: Decodable {
            let commit: Message
            struct Message: Decodable { let message: String }
        }
        enum CodingKeys: String, CodingKey {
            case status, commits
            case aheadBy = "ahead_by"
            case htmlUrl = "html_url"
        }
    }

    private enum CompareResult {
        case ahead(Int, [String], URL?)
        case identical, behind, diverged, notOnGitHub
    }

    private func fetchLatestRelease() async throws -> ReleaseDTO {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        let (data, http) = try await data(from: url)
        if http.statusCode == 404 { throw UpdateError.noRelease }
        try throwIfFailed(http, bodyHint: String(data: data, encoding: .utf8))
        do {
            return try JSONDecoder().decode(ReleaseDTO.self, from: data)
        } catch {
            throw UpdateError.http(http.statusCode, String(data: data, encoding: .utf8) ?? error.localizedDescription)
        }
    }

    private func fetchManifest(from release: ReleaseDTO) async throws -> ManifestDTO {
        guard let asset = release.assets.first(where: { $0.name == "manifest.json" }),
              let url = URL(string: asset.browserDownloadUrl) else {
            throw UpdateError.malformedManifest("release has no manifest.json asset")
        }
        let (data, http) = try await data(from: url)
        try throwIfFailed(http, bodyHint: String(data: data, encoding: .utf8))
        let manifest: ManifestDTO
        do {
            manifest = try JSONDecoder().decode(ManifestDTO.self, from: data)
        } catch {
            throw UpdateError.malformedManifest(error.localizedDescription)
        }
        guard manifest.schemaVersion >= 1 else {
            throw UpdateError.malformedManifest("unsupported schemaVersion \(manifest.schemaVersion)")
        }
        return manifest
    }

    private func zipURL(in release: ReleaseDTO, named name: String) -> URL? {
        release.assets.first(where: { $0.name == name }).flatMap { URL(string: $0.browserDownloadUrl) }
    }

    private func compare(ours: String, theirs: String) async throws -> CompareResult {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/compare/\(ours)...\(theirs)")!
        let (data, http) = try await data(from: url)
        if http.statusCode == 404 { return .notOnGitHub }
        try throwIfFailed(http, bodyHint: String(data: data, encoding: .utf8))
        let dto = try JSONDecoder().decode(ComparisonDTO.self, from: data)
        let compareURL = URL(string: dto.htmlUrl)
        let subjects = dto.commits.suffix(5).reversed().map { firstLine($0.commit.message) }
        switch dto.status {
        case "ahead":
            return .ahead(dto.aheadBy, subjects, compareURL)
        case "identical":
            return .identical
        case "behind":
            return .behind
        case "diverged":
            return .diverged
        default:
            return .diverged
        }
    }

    private func firstLine(_ message: String) -> String {
        String(message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: githubRequest(url))
        return (data, try requireHTTP(response))
    }

    private func githubRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Dosa/\(BuildInfo.shortVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    private func requireHTTP(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.http(0, "No HTTP response received.")
        }
        return http
    }

    private func throwIfFailed(_ http: HTTPURLResponse, bodyHint: String?) throws {
        let status = http.statusCode
        guard !(200..<300).contains(status) else { return }
        if (status == 403 || status == 429),
           http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap(TimeInterval.init)
                .map { Date(timeIntervalSince1970: $0) }
            throw UpdateError.rateLimited(reset)
        }
        throw UpdateError.http(status, bodyHint ?? "")
    }

    // MARK: - Plumbing

    private func probeDestinationWritable() {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let probe = parent.appendingPathComponent(".dosa-write-probe-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
            try FileManager.default.removeItem(at: probe)
            destinationWritable = true
        } catch {
            destinationWritable = false
        }
    }

    private func cleanupStaging() {
        if let stagingDir {
            try? FileManager.default.removeItem(at: stagingDir)
        }
        stagingDir = nil
        stagedApp = nil
    }

    private func markSuccessfulCheck() {
        lastCheckedAt = Date()
        UserDefaults.standard.set(Date.timeIntervalSinceReferenceDate, forKey: AppSettings.lastUpdateCheckKey)
    }

    private func setError(_ error: Error) {
        errorMessage = error.localizedDescription
        errorDetail = (error as? DetailedError)?.errorDetail
    }

    private static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dosa", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func parseISO8601(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func architectureSlices(_ arch: String) -> [String] {
        arch.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func currentMachineCanRun(_ slices: [String]) -> Bool {
        let set = Set(slices.map { $0.lowercased() })
        #if arch(arm64)
        return set.contains("arm64") || set.contains("x86_64")
        #else
        return set.contains("x86_64")
        #endif
    }

    private static func osAtLeast(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
        )
    }
}
