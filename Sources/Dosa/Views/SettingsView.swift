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
    var transcriptionEngine: String?
    var notesVerbosity: Int?
    var theme: String?
    var accentOverride: String?
    var dosaNotesColor: String?
    var notesPrompt: String?
    var transcriptPrompt: String?
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var notion: NotionManager

    @AppStorage(AppSettings.userNameKey) private var userName = ""
    @AppStorage(AppSettings.appearanceKey) private var appearance = "auto"
    @AppStorage(AppSettings.verbosityKey) private var verbosity = AppSettings.defaultVerbosity
    @AppStorage(AppSettings.dosaColorKey) private var dosaColor = "Theme Default"
    @AppStorage(AppSettings.themeKey) private var themeName = "Classic"
    @AppStorage(AppSettings.accentOverrideKey) private var accentOverride = "Theme Default"
    @AppStorage(AppSettings.apiKeyKey) private var apiKey = ""
    @AppStorage(AppSettings.modelKey) private var model = AppSettings.defaultModel
    @AppStorage(AppSettings.llmProviderKey) private var defaultProvider = "Gemini"
    @AppStorage(AppSettings.deepseekAPIKeyKey) private var deepseekAPIKey = ""
    @AppStorage(AppSettings.deepseekModelKey) private var deepseekModel = AppSettings.defaultDeepSeekModel
    @AppStorage(AppSettings.transcriptionEngineKey) private var transcriptionEngine = AppSettings.TranscriptionEngine.gemini.rawValue
    @AppStorage(AppSettings.notesPromptKey) private var notesPrompt = AppSettings.defaultNotesPrompt
    @AppStorage(AppSettings.transcriptPromptKey) private var transcriptPrompt = AppSettings.defaultTranscriptPrompt

    @State private var backupStatus: String?
    @State private var notesPromptExpanded = false
    @State private var transcriptPromptExpanded = false
    @State private var selectedTab = "Gemini"

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
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        notion.cancelConnect()
                    }
                }
            case .connected(let workspace):
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
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
                            .foregroundStyle(.secondary)
                    } else if let destination = notion.destination {
                        Text("“\(destination.title)” database")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let databaseURL = notion.databaseURL {
                            Button("Open") {
                                NSWorkspace.shared.open(databaseURL)
                            }
                        }
                    } else {
                        Text("“Dosa Notes” database")
                            .foregroundStyle(.secondary)
                        Button("Create Now") {
                            Task {
                                await notion.setUpDatabase()
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Notion")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your own Notion account (opens the browser). Dosa creates a private “Dosa Notes” database in your workspace and exports notes there via Export to Notion in a note's ⋯ menu.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let notionError = notion.errorMessage {
                    Text(notionError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            let key = provider == "DeepSeek" ? deepseekAPIKey : apiKey
            return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Settings", systemImage: "gearshape")
                    .font(.headline)
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
                    Text("Profile")
                } footer: {
                    Text("Told to the AI so it labels your voice with the right name in transcripts and notes.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
                    if transcriptionEngine == AppSettings.TranscriptionEngine.gemini.rawValue,
                       apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label("Gemini (Cloud) transcription needs a Gemini API key — add one in the LLM Provider section below.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if transcriptionEngine == AppSettings.TranscriptionEngine.appleAdvanced.rawValue,
                       !AppleTranscriber.advancedAvailable {
                        Label("On-Device (Advanced) needs macOS 26 or later — this Mac will use On-Device (Basic) instead.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text("Transcription")
                } footer: {
                    Text(transcriptionEngineBlurb)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section("LLM Provider") {
                    if configuredProviders.isEmpty {
                        Text("Add an API key below — the provider you configure becomes the default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Picker("Default Provider", selection: $defaultProvider) {
                            ForEach(configuredProviders, id: \.self) { provider in
                                Text(provider)
                            }
                        }
                    }

                    Picker("Provider", selection: $selectedTab) {
                        ForEach(Self.providers, id: \.self) { provider in
                            Text(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if selectedTab == "Gemini" {
                        SecureField("API Key", text: $apiKey)
                        Link("Get a free API key at ai.google.dev →",
                             destination: URL(string: "https://ai.google.dev/gemini-api/docs/api-key")!)
                            .font(.caption)
                        Picker("Model", selection: $model) {
                            ForEach(AppSettings.availableModels, id: \.self) { name in
                                Text(name)
                            }
                        }
                    } else if selectedTab == "DeepSeek" {
                        SecureField("API Key", text: $deepseekAPIKey)
                        Link("Get an API key at platform.deepseek.com →",
                             destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                            .font(.caption)
                        Picker("Model", selection: $deepseekModel) {
                            ForEach(AppSettings.availableDeepSeekModels, id: \.self) { name in
                                Text(name)
                            }
                        }
                        Text("DeepSeek generates your notes but can't transcribe audio — recordings use the engine picked in the Transcription section above. A Gemini key is only needed if that engine is Gemini (Cloud).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("\(selectedTab) support is coming soon. Until then Dosa uses Gemini for transcription and note generation.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }

                notionSection

                Section {
                    VStack(spacing: 6) {
                        Slider(
                            value: Binding(
                                get: { Double(verbosity) },
                                set: { verbosity = Int($0.rounded()) }
                            ),
                            in: 0...4,
                            step: 1
                        ) {
                            EmptyView()
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        HStack {
                            Text("More Succinct")
                            Spacer()
                            Text("Balanced")
                            Spacer()
                            Text("More Detailed")
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)

                } header: {
                    Text("Notes Style: \(AppSettings.verbosityLevelNames[min(max(verbosity, 0), 4)])")
                } footer: {
                    Text("Controls how succinct or detailed generated notes are. Fills the {{verbosity}} placeholder in the prompt below.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    DisclosureGroup(isExpanded: $notesPromptExpanded) {
                        TextEditor(text: $notesPrompt)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(height: 180)
                        HStack {
                            Text("Placeholders: {{title}}, {{date}}, {{user_name}}, {{verbosity}}, {{manual_notes}}, {{transcript}}")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Reset to Default") {
                                notesPrompt = AppSettings.defaultNotesPrompt
                            }
                        }
                    } label: {
                        promptGroupLabel("Note Generation Prompt", isExpanded: $notesPromptExpanded)
                    }
                } footer: {
                    Text("Your manual notes are always kept (with spelling and grammar corrected) in the primary text color; Dosa's additions render in grey.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    DisclosureGroup(isExpanded: $transcriptPromptExpanded) {
                        TextEditor(text: $transcriptPrompt)
                            .font(.system(size: 11, design: .monospaced))
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
                    HStack(spacing: 10) {
                        ForEach(Theme.presetNames, id: \.self) { name in
                            themeCard(name)
                        }
                    }
                    HStack(spacing: 10) {
                        Text("Accent Override")
                        Spacer()
                        ForEach(Theme.accentOverrideOptions, id: \.self) { name in
                            accentSwatch(name)
                        }
                    }
                    HStack(spacing: 10) {
                        Text("Dosa Notes Color")
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
                    .onChange(of: appearance) { _, _ in
                        AppSettings.applyAppearance()
                    }
                } header: {
                    Text("Theme")
                } footer: {
                    Text("Each theme is a matched palette for buttons, icons, backgrounds, and highlights. The accent and Dosa-notes overrides recolor on top of any theme.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
                    Text("Backup")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Exports your settings as a JSON file you can import into Dosa on another machine. API keys are not included — enter them separately on the other machine.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if let backupStatus {
                            Text(backupStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 600, height: 660)
        .onAppear {
            model = AppSettings.resolveModel(model)
            deepseekModel = AppSettings.resolveDeepSeekModel(deepseekModel)
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
                    .font(.caption.weight(isSelected ? .semibold : .regular))
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
    }

    private func promptGroupLabel(_ title: String, isExpanded: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.body.weight(.medium))
            Spacer()
            Text(isExpanded.wrappedValue ? "Click to collapse" : "Click to expand & customize")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                isExpanded.wrappedValue.toggle()
            }
        }
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
            transcriptionEngine: transcriptionEngine,
            notesVerbosity: verbosity,
            theme: themeName,
            accentOverride: accentOverride,
            dosaNotesColor: dosaColor,
            notesPrompt: notesPrompt,
            transcriptPrompt: transcriptPrompt
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
            if let value = snapshot.transcriptionEngine,
               AppSettings.TranscriptionEngine(rawValue: value) != nil { transcriptionEngine = value }
            if let value = snapshot.notesVerbosity { verbosity = min(max(value, 0), 4) }
            if let value = snapshot.theme, Theme.presetNames.contains(value) { themeName = value }
            if let value = snapshot.accentOverride, Theme.accentOverrideOptions.contains(value) { accentOverride = value }
            if let value = snapshot.dosaNotesColor,
               (["Theme Default"] + AppSettings.dosaColorOptions).contains(value) { dosaColor = value }
            if let value = snapshot.notesPrompt { notesPrompt = value }
            if let value = snapshot.transcriptPrompt { transcriptPrompt = value }
            AppSettings.applyAppearance()
            backupStatus = "Settings imported from \(url.lastPathComponent)."
        } catch {
            backupStatus = "Import failed: \(error.localizedDescription)"
        }
    }
}
