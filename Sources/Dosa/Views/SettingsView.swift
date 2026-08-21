import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct SettingsSnapshot: Codable {
    var version: Int? = 1
    var userName: String?
    var appearance: String?
    var geminiAPIKey: String?
    var geminiModel: String?
    var llmProvider: String?
    var deepseekModel: String?
    var anthropicModel: String?
    var transcriptionEngine: String?
    var notesVerbosity: Int?
    var theme: String?
    var accentOverride: String?
    var fontFamily: String?
    var textSize: String?
    var dosaNotesColor: String?
    var notesPrompt: String?
    var transcriptPrompt: String?
    var notificationsEnabled: Bool?
    var automaticMode: Bool?
    var noteTemplates: [NoteTemplate]?
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var templates: TemplateStore
    @EnvironmentObject private var notion: NotionManager
    @EnvironmentObject private var calendar: GoogleCalendarManager
    @EnvironmentObject private var notifier: NotificationManager
    @EnvironmentObject private var updater: UpdateManager
    @EnvironmentObject private var recorder: AudioRecorder
    @EnvironmentObject private var generator: GenerationManager

    @AppStorage(AppSettings.userNameKey) private var userName = ""
    @AppStorage(AppSettings.appearanceKey) private var appearance = "auto"
    @AppStorage(AppSettings.verbosityKey) private var verbosity = AppSettings.defaultVerbosity
    @AppStorage(AppSettings.dosaColorKey) private var dosaColor = "Theme Default"
    @AppStorage(AppSettings.themeKey) private var themeName = "Classic"
    @AppStorage(AppSettings.accentOverrideKey) private var accentOverride = "Theme Default"
    @AppStorage(AppSettings.fontFamilyKey) private var fontFamily = AppFontChoice.system.rawValue
    @AppStorage(AppSettings.textSizeKey) private var textSize = AppTextSize.regular.rawValue
    @AppStorage(AppSettings.notificationsEnabledKey) private var notificationsEnabled = true
    @AppStorage(AppSettings.automaticModeKey) private var automaticMode = false
    @AppStorage(AppSettings.automaticUpdateCheckKey) private var automaticUpdateCheck = true
    @AppStorage(AppSettings.apiKeyKey) private var apiKey = ""
    @AppStorage(AppSettings.modelKey) private var model = AppSettings.defaultModel
    @AppStorage(AppSettings.llmProviderKey) private var defaultProvider = "Gemini"
    @AppStorage(AppSettings.deepseekAPIKeyKey) private var deepseekAPIKey = ""
    @AppStorage(AppSettings.deepseekModelKey) private var deepseekModel = AppSettings.defaultDeepSeekModel
    @AppStorage(AppSettings.anthropicAPIKeyKey) private var anthropicAPIKey = ""
    @AppStorage(AppSettings.anthropicModelKey) private var anthropicModel = AppSettings.defaultAnthropicModel
    @AppStorage(AppSettings.transcriptionEngineKey) private var transcriptionEngine = AppSettings.TranscriptionEngine.gemini.rawValue
    @AppStorage(AppSettings.notesPromptKey) private var notesPrompt = AppSettings.defaultNotesPrompt
    @AppStorage(AppSettings.transcriptPromptKey) private var transcriptPrompt = AppSettings.defaultTranscriptPrompt

    @State private var backupStatus: String?
    @State private var notesPromptExpanded = false
    @State private var transcriptPromptExpanded = false
    @State private var expandedTemplateIds: Set<UUID> = []
    @State private var selectedTab = "Gemini"
    @State private var showingClientPasteSheet = false
    @State private var pastedClientJSON = ""

    private static let providers = ["Gemini", "Anthropic", "OpenAI", "DeepSeek"]

    @ViewBuilder
    private var notionSection: some View {
        Section {
            switch notion.connectionState {
            case .disconnected:
                HStack {
                    Button("Connect Notion Account…") {
                        notion.connect()
                    }
                    Spacer()
                }
            case .connecting:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for authorization in your browser…")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Spacer()
                    Button("Cancel") {
                        notion.cancelConnect()
                    }
                }
            case .connected(let workspace):
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.current.successTextColor)
                    Text("Connected to \(workspace)")
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        notion.disconnect()
                    }
                }
                HStack {
                    Text("Save notes to")
                    Spacer()
                    if notion.settingUpDatabase {
                        ProgressView()
                            .controlSize(.small)
                        Text("Creating “Dosa Notes” database…")
                            .foregroundStyle(Theme.secondaryTextColor)
                    } else if let destination = notion.destination {
                        Text("“\(destination.title)” database")
                            .foregroundStyle(Theme.secondaryTextColor)
                            .lineLimit(1)
                        if let databaseURL = notion.databaseURL {
                            Button("Open") {
                                NSWorkspace.shared.open(databaseURL)
                            }
                        }
                    } else {
                        Text("“Dosa Notes” database")
                            .foregroundStyle(Theme.secondaryTextColor)
                        Button("Create Now") {
                            Task {
                                await notion.setUpDatabase()
                            }
                        }
                    }
                }
            }
        } header: {
            sectionHeader("Notion")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your own Notion account (opens the browser). Dosa creates a private “Dosa Notes” database in your workspace and exports notes there via Export to Notion in a note's ⋯ menu.")
                    .appFont(.caption)
                    .foregroundStyle(Theme.tertiaryTextColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let notionError = notion.errorMessage {
                    Text(notionError)
                        .appFont(.caption)
                        .foregroundStyle(Theme.current.dangerTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var googleCalendarSection: some View {
        Section {
            switch calendar.connectionState {
            case .unavailable:
                VStack(alignment: .leading, spacing: 8) {
                    Text("No Google OAuth client is configured. Create a Desktop client in the Google Cloud Console, then add the JSON it gives you.")
                        .appFont(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Choose client_secret.json…") { chooseGoogleClientFile() }
                        Button("Paste JSON…") {
                            pastedClientJSON = ""
                            showingClientPasteSheet = true
                        }
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .disconnected:
                HStack {
                    Button("Connect Google Calendar…") {
                        calendar.connect()
                    }
                    Spacer()
                }
            case .connecting:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for authorization in your browser…")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Spacer()
                    Button("Cancel") {
                        calendar.cancelConnect()
                    }
                }
            case .connected(let account):
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.current.successTextColor)
                    Text("Connected as \(account)")
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        calendar.disconnect()
                    }
                }
                if calendar.calendars.isEmpty {
                    Text("No calendars were returned for this account.")
                        .foregroundStyle(Theme.secondaryTextColor)
                } else {
                    ForEach(calendar.calendars) { item in
                        Toggle(isOn: Binding(
                            get: { calendar.selectedCalendarIDs.contains(item.id) },
                            set: { calendar.setCalendarSelected(item.id, selected: $0) }
                        )) {
                            HStack {
                                Text(item.name)
                                if item.isPrimary {
                                    Text("Primary")
                                        .appFont(.caption)
                                        .foregroundStyle(Theme.tertiaryTextColor)
                                }
                            }
                        }
                        .disabled(calendar.selectedCalendarIDs.contains(item.id) && calendar.selectedCalendarIDs.count == 1)
                    }
                }
                HStack {
                    if calendar.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing meetings…")
                            .foregroundStyle(Theme.secondaryTextColor)
                    } else if let last = calendar.lastSuccessfulSyncAt {
                        Text("Last refresh \(last.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(Theme.secondaryTextColor)
                    } else {
                        Text("Meetings haven’t synced yet.")
                            .foregroundStyle(Theme.secondaryTextColor)
                    }
                    Spacer()
                    Button("Refresh") {
                        Task { await calendar.refresh() }
                    }
                    .disabled(calendar.isRefreshing)
                }
            }
        } header: {
            sectionHeader("Google Calendar")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your Google account in the browser. Dosa reads the next 30 days of meetings from the calendars you select and shows them on the home screen. At least one calendar must stay selected.")
                    .appFont(.caption)
                    .foregroundStyle(Theme.tertiaryTextColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let clientID = calendar.activeClientID {
                    HStack(spacing: 6) {
                        Text("OAuth client \(clientID.prefix(12))…")
                            .appFont(.caption)
                            .foregroundStyle(Theme.tertiaryTextColor)
                        Button("Remove") { calendar.clearCredentials() }
                            .buttonStyle(.link)
                            .appFont(.caption)
                    }
                }
                if let calendarError = calendar.errorMessage {
                    Text(calendarError)
                        .appFont(.caption)
                        .foregroundStyle(Theme.current.dangerTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        Section {
            switch updater.state {
            case .idle, .upToDate:
                HStack {
                    Text(currentBuildLabel)
                    Spacer()
                    Button("Check for Updates") {
                        updater.check()
                    }
                }
            case .checking:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking GitHub…")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Spacer()
                    Button("Cancel") {
                        updater.cancel()
                    }
                }
            case .available(let update):
                availableUpdateRows(update)
            case .downloading(let progress):
                HStack(spacing: 10) {
                    if updater.downloadExpectedBytes > 0 {
                        ProgressView(value: progress)
                            .frame(maxWidth: 120)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(downloadCaption)
                        .foregroundStyle(Theme.secondaryTextColor)
                    Spacer()
                    Button("Cancel") {
                        updater.cancel()
                    }
                }
            case .verifying:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Verifying the download…")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Spacer()
                }
            case .readyToInstall(let update):
                if !updater.destinationWritable {
                    notWritableRows(update)
                } else {
                    HStack {
                        Button("Install and Restart") {
                            confirmInstall()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Cancel") {
                            updater.cancel()
                        }
                        Spacer()
                    }
                    Label("Because Dosa is signed ad-hoc, macOS treats each new build as a different app. After the restart you'll be asked again for Microphone and Screen & System Audio Recording, and notifications may need re-approving.",
                          systemImage: "exclamationmark.triangle.fill")
                        .appFont(.caption)
                        .foregroundStyle(Theme.current.warningTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .installing:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Restarting Dosa…")
                        .foregroundStyle(Theme.secondaryTextColor)
                    Spacer()
                }
            }

            if let statusNote = updater.statusNote {
                Text(statusNote)
                    .appFont(.caption)
                    .foregroundStyle(Theme.secondaryTextColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("Check for updates when Dosa starts", isOn: $automaticUpdateCheck)
            Link("View releases on GitHub →", destination: UpdateManager.releasesPageURL)
                .appFont(.caption)
        } header: {
            sectionHeader("Updates")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Updates are built from the latest commit on main and downloaded from GitHub Releases. Because Dosa is signed ad-hoc rather than with a Developer ID certificate, macOS treats each update as a new app — you'll be asked again for Microphone and Screen & System Audio Recording permission after installing.")
                    .appFont(.caption)
                    .foregroundStyle(Theme.tertiaryTextColor)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = updater.errorMessage {
                    Text(error)
                        .appFont(.caption)
                        .foregroundStyle(Theme.current.dangerTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let previous = updater.previousFailure {
                    Text(previous)
                        .appFont(.caption)
                        .foregroundStyle(Theme.current.dangerTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func availableUpdateRows(_ update: UpdateManager.Update) -> some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill")
            Text(update.commitCount > 0
                 ? "\(update.commitCount) new commits available"
                 : "An update is available")
            Spacer()
            if updater.destinationWritable {
                Button("Download Update") {
                    updater.downloadAndStage()
                }
            } else {
                Button("Open Releases Page") {
                    NSWorkspace.shared.open(update.releaseURL)
                }
            }
        }
        if !updater.destinationWritable {
            notWritableCopy
        }
        ForEach(Array(update.subjects.enumerated()), id: \.offset) { _, subject in
            Text(subject)
                .appFont(.caption)
                .foregroundStyle(Theme.tertiaryTextColor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let compareURL = update.compareURL {
            Link("View all changes on GitHub →", destination: compareURL)
                .appFont(.caption)
        }
    }

    @ViewBuilder
    private func notWritableRows(_ update: UpdateManager.Update) -> some View {
        notWritableCopy
        Button("Open Releases Page") {
            NSWorkspace.shared.open(update.releaseURL)
        }
    }

    private var notWritableCopy: some View {
        (Text("Dosa can't update itself here. ").fontWeight(.semibold)
         + Text("\(Bundle.main.bundleURL.deletingLastPathComponent().path) can only be changed by an administrator on this Mac. Download the update and replace \(Bundle.main.bundleURL.path) yourself, or ask an admin."))
            .appFont(.caption)
            .foregroundStyle(Theme.secondaryTextColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentBuildLabel: String {
        var head = "Dosa \(BuildInfo.shortVersion)"
        if !BuildInfo.shortCommit.isEmpty {
            head += " (\(BuildInfo.shortCommit))"
        }
        var line = head
        if let raw = BuildInfo.commitDate, let date = UpdateManager.parseISO8601(raw) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            line += " · built \(formatter.string(from: date))"
        }
        if BuildInfo.isDirty {
            line += " (uncommitted changes)"
        }
        return line
    }

    private var downloadCaption: String {
        let received = updater.downloadReceivedBytes
        let expected = updater.downloadExpectedBytes
        if expected > 0 {
            return "Downloading… \(byteCount(received)) of \(byteCount(expected))"
        }
        if received > 0 {
            return "Downloading… \(byteCount(received))"
        }
        return "Downloading…"
    }

    private func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func confirmInstall() {
        var extra: [String] = []
        if let root = BuildInfo.repoCheckoutRoot {
            extra.append("Dosa is running from \(root.path)/build/Dosa.app. Installing overwrites that build output with the released one; your next `./build.sh` will overwrite it again.")
        }
        QuitGuard.requestInstallUpdate(
            recorder: recorder,
            generator: generator,
            appState: appState,
            extraWarnings: extra
        ) {
            updater.installAndRelaunch { dismiss() }
        }
    }

    @ViewBuilder
    private var templatesSection: some View {
        Section {
            ForEach($templates.templates) { $template in
                DisclosureGroup(isExpanded: templateExpanded(template.id)) {
                    TextField("Name", text: $template.name)
                    Text("Sections prefilled into a new note")
                        .appFont(.caption)
                        .foregroundStyle(Theme.tertiaryTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextEditor(text: $template.body)
                        .appMonoFont(size: 11)
                        .frame(height: 140)
                    Text("What the AI is told about this note type")
                        .appFont(.caption)
                        .foregroundStyle(Theme.tertiaryTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TextEditor(text: $template.promptContext)
                        .appMonoFont(size: 11)
                        .frame(height: 120)
                    HStack {
                        if template.builtInKey != nil {
                            Button("Reset to Default") {
                                templates.resetToDefault(id: template.id)
                            }
                        }
                        Spacer()
                        Button("Delete", role: .destructive) {
                            templates.delete(id: template.id)
                        }
                    }
                } label: {
                    promptGroupLabel(template.name, isExpanded: templateExpanded(template.id))
                }
            }
            HStack {
                Button("Add Template") {
                    let created = templates.add()
                    expandedTemplateIds.insert(created.id)
                }
                Spacer()
                Button("Restore Defaults") {
                    templates.restoreDefaults()
                }
            }
        } header: {
            sectionHeader("Note Templates")
        } footer: {
            Text("Templates appear under Templates in the ＋ menu in the sidebar. Choosing one prefills the note with its sections and tells the AI what kind of conversation it is, so the generated notes match. {{user_name}} works inside a template's AI context. Any template can be deleted, built-in ones included — Restore Defaults brings the four shipped templates back. A template only sets structure and context: generated notes stay a factual record either way, and never score or pass judgement on a conversation.")
                .appFont(.caption)
                .foregroundStyle(Theme.tertiaryTextColor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Shown on the tabs of providers that generate notes but can't take audio.
    @ViewBuilder
    private func textOnlyProviderNote(_ name: String) -> some View {
        Text("\(name) generates your notes but can't transcribe audio — recordings use the engine picked in the Transcription section above. A Gemini key is only needed if that engine is Gemini (Cloud).")
            .appFont(.caption)
            .foregroundStyle(Theme.secondaryTextColor)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One-line description of whichever transcription engine is selected.
    private var transcriptionEngineBlurb: String {
        switch AppSettings.TranscriptionEngine(rawValue: transcriptionEngine) ?? .gemini {
        case .gemini:
            return "Uploads audio to Google. Names each speaker individually."
        case .appleAdvanced:
            return "Private and free on this Mac. Separates you from others, but won't name them."
        case .appleBasic:
            return "Private and free on this Mac. Needs macOS Dictation on; separates you from others, but won't name them."
        }
    }

    /// Providers whose API key field is non-empty — the choices for the
    /// Default Provider picker. Derived from the view's own @AppStorage keys
    /// so the picker updates live as keys are typed or cleared.
    private var configuredProviders: [String] {
        AppSettings.supportedProviders.filter { provider in
            let key: String
            switch provider {
            case "Anthropic": key = anthropicAPIKey
            case "DeepSeek": key = deepseekAPIKey
            default: key = apiKey
            }
            return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Dosa Settings", systemImage: "gearshape")
                    .appFont(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section {
                    TextField("Your Name", text: $userName)
                } header: {
                    sectionHeader("Profile")
                } footer: {
                    Text("Told to the AI so it labels your voice with the right name in transcripts and notes.")
                        .appFont(.caption)
                        .foregroundStyle(Theme.tertiaryTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    Picker("Engine", selection: $transcriptionEngine) {
                        ForEach(AppSettings.TranscriptionEngine.allCases, id: \.rawValue) { engine in
                            Text(engine.displayName).tag(engine.rawValue)
                        }
                    }
                    .appFont(.body)
                    if transcriptionEngine == AppSettings.TranscriptionEngine.gemini.rawValue,
                       apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label("Gemini (Cloud) transcription needs a Gemini API key — add one in the LLM Provider section below.",
                              systemImage: "exclamationmark.triangle.fill")
                            .appFont(.caption)
                            .foregroundStyle(Theme.current.warningTextColor)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if transcriptionEngine == AppSettings.TranscriptionEngine.appleAdvanced.rawValue,
                       !AppleTranscriber.advancedAvailable {
                        Label(AppleTranscriber.runningMacOS26
                              ? "On-Device (Advanced) isn't in this build. This Mac is on macOS 26, but Dosa was compiled without the macOS 26 SDK — install Xcode 26 and rebuild. Until then this Mac will use On-Device (Basic)."
                              : "On-Device (Advanced) needs macOS 26 or later — this Mac will use On-Device (Basic) instead.",
                              systemImage: "exclamationmark.triangle.fill")
                            .appFont(.caption)
                            .foregroundStyle(Theme.current.warningTextColor)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    sectionHeader("Transcription")
                } footer: {
                    Text(transcriptionEngineBlurb)
                        .appFont(.caption)
                        .foregroundStyle(Theme.tertiaryTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    if configuredProviders.isEmpty {
                        Text("Add an API key below — the provider you configure becomes the default.")
                            .appFont(.caption)
                            .foregroundStyle(Theme.secondaryTextColor)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Picker("Default Provider", selection: $defaultProvider) {
                            ForEach(configuredProviders, id: \.self) { provider in
                                Text(provider)
                            }
                        }
                        .appFont(.body)
                    }

                    Picker(selection: $selectedTab) {
                        ForEach(Self.providers, id: \.self) { provider in
                            Text(provider)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("LLM provider")
                    .frame(maxWidth: .infinity)

                    if selectedTab == "Gemini" {
                        SecureField("API Key", text: $apiKey)
                        Link("Get a free API key at ai.google.dev →",
                             destination: URL(string: "https://ai.google.dev/gemini-api/docs/api-key")!)
                            .appFont(.caption)
                        Picker("Model", selection: $model) {
                            ForEach(AppSettings.availableModels(for: "Gemini"), id: \.self) { name in
                                Text(name)
                            }
                        }
                        .appFont(.body)
                        Text("Applies to note generation. Transcription always uses \(AppSettings.transcriptionModel) — the cheapest tier that handles audio.")
                            .appFont(.caption)
                            .foregroundStyle(Theme.secondaryTextColor)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if selectedTab == "Anthropic" {
                        SecureField("API Key", text: $anthropicAPIKey)
                        Link("Get an API key at platform.claude.com →",
                             destination: URL(string: "https://platform.claude.com/settings/keys")!)
                            .appFont(.caption)
                        Picker("Model", selection: $anthropicModel) {
                            ForEach(AppSettings.availableModels(for: "Anthropic"), id: \.self) { name in
                                Text(name)
                            }
                        }
                        .appFont(.body)
                        textOnlyProviderNote("Claude")
                    } else if selectedTab == "DeepSeek" {
                        SecureField("API Key", text: $deepseekAPIKey)
                        Link("Get an API key at platform.deepseek.com →",
                             destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                            .appFont(.caption)
                        Picker("Model", selection: $deepseekModel) {
                            ForEach(AppSettings.availableModels(for: "DeepSeek"), id: \.self) { name in
                                Text(name)
                            }
                        }
                        .appFont(.body)
                        textOnlyProviderNote("DeepSeek")
                    } else {
                        Text("\(selectedTab) support is coming soon.")
                            .appFont(.callout)
                            .foregroundStyle(Theme.secondaryTextColor)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                } header: {
                    sectionHeader("LLM Provider")
                }

                Section {
                    Toggle("Transcribe and generate notes automatically", isOn: $automaticMode)
                } header: {
                    sectionHeader("Automatic Mode")
                } footer: {
                    Text("As soon as you stop a recording, Dosa transcribes it and generates notes — no need to press Generate Notes. Because this can finish while you're in another note or another app, Dosa tells you when the notes are ready with an in-app message or a notification.")
                        .appFont(.caption)
                        .foregroundStyle(Theme.tertiaryTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                notionSection

                googleCalendarSection

                Section {
                    // Shared with the floating bar's quick-settings panel, which
                    // writes the same key — the two are meant to be the same control.
                    NotesStyleSlider(level: $verbosity)
                        .padding(.vertical, 4)
                } header: {
                    sectionHeader("Notes Style: \(AppSettings.verbosityLevelNames[min(max(verbosity, 0), 4)])")
                } footer: {
                    Text("Controls how succinct or detailed generated notes are. Fills the {{verbosity}} placeholder in the prompt below.")
                        .appFont(.caption)
                        .foregroundStyle(Theme.tertiaryTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                templatesSection

                Section {
                    DisclosureGroup(isExpanded: $notesPromptExpanded) {
                        TextEditor(text: $notesPrompt)
                            .appMonoFont(size: 11)
                            .frame(height: 180)
                        HStack {
                            Text("Placeholders: {{title}}, {{date}}, {{user_name}}, {{verbosity}}, {{template_context}}, {{manual_notes}}, {{transcript}}")
                                .appFont(.caption)
                                .foregroundStyle(Theme.secondaryTextColor)
                            Spacer()
                            Button("Reset to Default") {
                                notesPrompt = AppSettings.defaultNotesPrompt
                            }
                        }
                        if !notesPrompt.contains("{{template_context}}") {
                            Text("Your customized prompt doesn't include `{{template_context}}` — template guidance will be added at the top of the prompt instead. Reset to Default to place it inline.")
                                .appFont(.caption)
                                .foregroundStyle(Theme.tertiaryTextColor)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } label: {
                        promptGroupLabel("Note Generation Prompt", isExpanded: $notesPromptExpanded)
                    }
                } footer: {
                    Text("Your manual notes are always kept (with spelling and grammar corrected) in the primary text color; Dosa's additions render in grey.")
                        .appFont(.caption)
                        .foregroundStyle(Theme.tertiaryTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    DisclosureGroup(isExpanded: $transcriptPromptExpanded) {
                        TextEditor(text: $transcriptPrompt)
                            .appMonoFont(size: 11)
                            .frame(height: 130)
                        HStack {
                            Spacer()
                            Button("Reset to Default") {
                                transcriptPrompt = AppSettings.defaultTranscriptPrompt
                            }
                        }
                    } label: {
                        promptGroupLabel("Transcription Prompt", isExpanded: $transcriptPromptExpanded)
                    }
                }

                Section {
                    Toggle("Enable notifications", isOn: $notificationsEnabled)
                    if notifier.authorizationDenied {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                            Text("macOS is blocking Dosa's notifications.")
                            Spacer()
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string:
                                    "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                            }
                        }
                        .appFont(.caption)
                    }
                } header: {
                    sectionHeader("Notifications")
                } footer: {
                    Text("Dosa tells you when a recording is saved and when generated notes are ready. macOS banners only appear when Dosa isn't the active app — while you're in Dosa you'll get an in-app message instead.")
                        .appFont(.caption)
                        .foregroundStyle(Theme.tertiaryTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: notificationsEnabled) { _, enabled in
                    guard enabled else { return }
                    Task { await notifier.ensureAuthorized() }
                }
                .task { await notifier.ensureAuthorized() }

                Section {
                    HStack(spacing: 10) {
                        ForEach(Theme.presetNames, id: \.self) { name in
                            themeCard(name)
                        }
                    }
                    HStack(spacing: 10) {
                        Text("Accent Override")
                            .appFont(.body)
                        Spacer()
                        ForEach(Theme.accentOverrideOptions, id: \.self) { name in
                            accentSwatch(name)
                        }
                    }
                    HStack(spacing: 10) {
                        Text("Dosa Notes Color")
                            .appFont(.body)
                        Spacer()
                        ForEach(["Theme Default"] + AppSettings.dosaColorOptions, id: \.self) { name in
                            colorSwatch(name)
                        }
                    }
                    Picker("Appearance", selection: $appearance) {
                        Text("Auto (System)").tag("auto")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .appFont(.body)
                    .onChange(of: appearance) { _, _ in
                        AppSettings.applyAppearance()
                    }
                    Picker("Font", selection: $fontFamily) {
                        ForEach(AppFontChoice.allCases) { choice in
                            Text(choice.displayName)
                                .font(Typography.font(.body, choice: choice)) // system-font: each row previews its own face
                                .tag(choice.rawValue)
                        }
                    }
                    .appFont(.body)
                    Picker("Text Size", selection: $textSize) {
                        ForEach(AppTextSize.allCases) { size in
                            Text(size.displayName).tag(size.rawValue)
                        }
                    }
                    .appFont(.body)
                    Text("The quick brown fox jumps over the lazy dog.")
                        .appFont(.body)
                        .foregroundStyle(Theme.secondaryTextColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    sectionHeader("Theme")
                } footer: {
                    Text("Each theme is a matched palette for buttons, icons, backgrounds, and highlights. The accent, Dosa-notes, and font choices apply on top of any theme. Code, timers, and API keys stay monospaced.")
                        .appFont(.caption)
                        .foregroundStyle(Theme.tertiaryTextColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    HStack {
                        Button {
                            exportSettings()
                        } label: {
                            Label("Export Settings…", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            importSettings()
                        } label: {
                            Label("Import Settings…", systemImage: "square.and.arrow.down")
                        }
                        Spacer()
                    }
                } header: {
                    sectionHeader("Backup")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Exports your settings as a JSON file you can import into Dosa on another machine. API keys, Notion credentials, and Google Calendar tokens are not included — reconnect those separately on the other machine.")
                            .appFont(.caption)
                            .foregroundStyle(Theme.tertiaryTextColor)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let backupStatus {
                            Text(backupStatus)
                                .appFont(.caption)
                                .foregroundStyle(Theme.secondaryTextColor)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                updatesSection
            }
            .formStyle(.grouped)
        }
        .frame(width: 600, height: 660)
        .appFontScope()
        .onAppear {
            model = AppSettings.resolveModel(model)
            deepseekModel = AppSettings.resolveDeepSeekModel(deepseekModel)
            anthropicModel = AppSettings.resolveAnthropicModel(anthropicModel)
            let configured = configuredProviders
            if !AppSettings.supportedProviders.contains(defaultProvider)
                || (!configured.isEmpty && !configured.contains(defaultProvider)) {
                defaultProvider = configured.first ?? "Gemini"
            }
            selectedTab = defaultProvider
        }
        .onDisappear {
            appState.themeRefreshTick += 1
        }
        .sheet(isPresented: $showingClientPasteSheet) {
            googleClientPasteSheet
        }
    }

    private var googleClientPasteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste Google OAuth Client JSON")
                .appFont(.headline)
            Text("The contents of the client_secret….json downloaded from the Google Cloud Console.")
                .appFont(.caption)
                .foregroundStyle(Theme.secondaryTextColor)
            TextEditor(text: $pastedClientJSON)
                .appMonoFont(.caption)
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Cancel") { showingClientPasteSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    calendar.setCredentials(json: pastedClientJSON)
                    showingClientPasteSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pastedClientJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .appFontScope()
    }

    private func colorSwatch(_ name: String) -> some View {
        let resolvedName = name == "Theme Default"
            ? Theme.palette(named: themeName).defaultDosaColorName
            : name
        return swatchButton(
            color: Color(nsColor: DiffEngine.color(named: resolvedName)),
            isSelected: dosaColor == name,
            help: name == "Theme Default" ? "Theme Default (\(resolvedName))" : name
        ) {
            dosaColor = name
        }
    }

    private func accentSwatch(_ name: String) -> some View {
        let color = name == "Theme Default"
            ? Theme.palette(named: themeName).accent
            : (Theme.accentOverrideColor(named: name) ?? .systemBlue)
        return swatchButton(
            color: Color(nsColor: color),
            isSelected: accentOverride == name,
            help: name
        ) {
            accentOverride = name
        }
    }

    private func swatchButton(color: Color, isSelected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if isSelected {
                    Circle()
                        .strokeBorder(Theme.current.accentColor, lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
                Circle()
                    .fill(color)
                    .frame(width: 16, height: 16)
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
        // Color is the only visual signal here, so VoiceOver needs the name
        // and selection state spelled out explicitly.
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func themeCard(_ name: String) -> some View {
        let palette = Theme.palette(named: name)
        let isSelected = themeName == name
        return Button {
            themeName = name
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(nsColor: palette.accent))
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(Color(nsColor: palette.highlight))
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(Color(nsColor: palette.editorBackground))
                        .overlay(Circle().strokeBorder(.quaternary))
                        .frame(width: 12, height: 12)
                }
                Text(name)
                    .appFont(.caption, weight: isSelected ? .semibold : .regular)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color(nsColor: palette.accent).opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color(nsColor: palette.accent) : Color.secondary.opacity(0.3),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("\(name) theme")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func templateExpanded(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedTemplateIds.contains(id) },
            set: { expanded in
                if expanded {
                    expandedTemplateIds.insert(id)
                } else {
                    expandedTemplateIds.remove(id)
                }
            }
        )
    }

    /// Grouped-Form section headers derive their smaller, heavier look from the
    /// default text style — once `appFontScope` sets an explicit environment font
    /// on the body, they need their own explicit role to keep that look.
    private func sectionHeader(_ title: String) -> some View {
        Text(title).appFont(.subheadline, weight: .semibold)
    }

    private func promptGroupLabel(_ title: String, isExpanded: Binding<Bool>) -> some View {
        // A real Button, not a tap-gesture-only label, so this is reachable by
        // keyboard/VoiceOver as well as by mouse.
        Button {
            withAnimation {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack {
                Text(title)
                    .appFont(.body, weight: .medium)
                Spacer()
                Text(isExpanded.wrappedValue ? "Click to collapse" : "Click to expand & customize")
                    .appFont(.caption)
                    .foregroundStyle(Theme.tertiaryTextColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "dosa-settings.json"
        panel.title = "Export Dosa Settings"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = SettingsSnapshot(
            userName: userName,
            appearance: appearance,
            geminiModel: model,
            llmProvider: defaultProvider,
            deepseekModel: deepseekModel,
            anthropicModel: anthropicModel,
            transcriptionEngine: transcriptionEngine,
            notesVerbosity: verbosity,
            theme: themeName,
            accentOverride: accentOverride,
            fontFamily: fontFamily,
            textSize: textSize,
            dosaNotesColor: dosaColor,
            notesPrompt: notesPrompt,
            transcriptPrompt: transcriptPrompt,
            notificationsEnabled: notificationsEnabled,
            automaticMode: automaticMode,
            noteTemplates: templates.templates
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: url)
            backupStatus = "Settings exported to \(url.lastPathComponent)."
        } catch {
            backupStatus = "Export failed: \(error.localizedDescription)"
        }
    }

    private func chooseGoogleClientFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Choose Google OAuth Client JSON"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        calendar.setCredentials(from: url)
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Dosa Settings"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(contentsOf: url))
            if let value = snapshot.userName { userName = value }
            if let value = snapshot.appearance { appearance = value }
            if let value = snapshot.geminiAPIKey { apiKey = value }
            if let value = snapshot.geminiModel { model = AppSettings.resolveModel(value) }
            if let value = snapshot.llmProvider, AppSettings.supportedProviders.contains(value) { defaultProvider = value }
            if let value = snapshot.deepseekModel { deepseekModel = AppSettings.resolveDeepSeekModel(value) }
            if let value = snapshot.anthropicModel { anthropicModel = AppSettings.resolveAnthropicModel(value) }
            if let value = snapshot.transcriptionEngine,
               AppSettings.TranscriptionEngine(rawValue: value) != nil { transcriptionEngine = value }
            if let value = snapshot.notesVerbosity { verbosity = min(max(value, 0), 4) }
            if let value = snapshot.theme, Theme.presetNames.contains(value) { themeName = value }
            if let value = snapshot.accentOverride, Theme.accentOverrideOptions.contains(value) { accentOverride = value }
            if let value = snapshot.fontFamily, AppFontChoice(rawValue: value) != nil { fontFamily = value }
            if let value = snapshot.textSize, AppTextSize(rawValue: value) != nil { textSize = value }
            if let value = snapshot.dosaNotesColor,
               (["Theme Default"] + AppSettings.dosaColorOptions).contains(value) { dosaColor = value }
            if let value = snapshot.notesPrompt { notesPrompt = value }
            if let value = snapshot.transcriptPrompt { transcriptPrompt = value }
            if let value = snapshot.notificationsEnabled { notificationsEnabled = value }
            if let value = snapshot.automaticMode { automaticMode = value }
            // No `!value.isEmpty` guard: with built-ins deletable, "no templates" is a
            // state worth exporting and restoring. Older JSON without the field decodes
            // to nil and is still skipped.
            if let value = snapshot.noteTemplates { templates.templates = value }
            AppSettings.applyAppearance()
            backupStatus = "Settings imported from \(url.lastPathComponent)."
        } catch {
            backupStatus = "Import failed: \(error.localizedDescription)"
        }
    }
}
