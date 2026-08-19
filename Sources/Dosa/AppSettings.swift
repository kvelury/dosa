import Foundation
import AppKit

enum AppSettings {
    static let userNameKey = "userName"
    static let appearanceKey = "appearanceMode"
    static let verbosityKey = "notesVerbosity"
    static let dosaColorKey = "dosaNotesColor"
    static let themeKey = "themeName"
    static let accentOverrideKey = "accentOverride"
    static let notificationsEnabledKey = "notificationsEnabled"
    static let automaticModeKey = "automaticMode"

    static var notificationsEnabled: Bool { bool(forKey: notificationsEnabledKey, default: true) }

    /// Off by default: the shipped behavior is that nothing runs until the user
    /// presses Generate Notes.
    static var automaticModeEnabled: Bool { bool(forKey: automaticModeKey, default: false) }

    /// Automatic mode *and* the credentials a run would need — mirroring the two
    /// key checks inside `GenerationManager.run`. The stop toast's wording and the
    /// enqueue guard both read this one property so they can never disagree: a
    /// toast promising "transcribing…" when no key is configured is worse than no
    /// toast at all.
    static var automaticModeWillRun: Bool {
        guard automaticModeEnabled else { return false }
        guard !storedAPIKey(for: currentProvider).isEmpty else { return false }
        if resolvedTranscriptionEngine == .gemini, storedAPIKey(for: "Gemini").isEmpty { return false }
        return true
    }

    /// Mirrors currentVerbosity's unset guard — UserDefaults returns a zero
    /// value for an unset key, which would wrongly treat "never set" as off.
    static func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }

    static let notionClientIdKey = "notionClientId"
    static let notionAccessTokenKey = "notionAccessToken"
    static let notionRefreshTokenKey = "notionRefreshToken"
    static let notionTokenExpiryKey = "notionTokenExpiry"
    static let notionTokenEndpointKey = "notionTokenEndpoint"
    static let notionWorkspaceKey = "notionWorkspaceName"
    static let notionDestTypeKey = "notionDestinationType"
    static let notionDestIdKey = "notionDestinationId"
    static let notionDestTitleKey = "notionDestinationTitle"
    static let notionTitlePropertyKey = "notionTitleProperty"
    static let notionDatabaseURLKey = "notionDatabaseURL"

    static let dosaColorOptions = ["Grey", "Purple", "Red", "Dark Blue", "Dark Green"]

    static var currentDosaColorName: String {
        let stored = UserDefaults.standard.string(forKey: dosaColorKey) ?? "Theme Default"
        return dosaColorOptions.contains(stored) ? stored : Theme.current.defaultDosaColorName
    }

    static var currentThemeName: String {
        let stored = UserDefaults.standard.string(forKey: themeKey) ?? "Classic"
        return Theme.presetNames.contains(stored) ? stored : "Classic"
    }

    static var currentAccentOverride: String {
        let stored = UserDefaults.standard.string(forKey: accentOverrideKey) ?? "Theme Default"
        return Theme.accentOverrideOptions.contains(stored) ? stored : "Theme Default"
    }
    static let apiKeyKey = "geminiAPIKey"
    static let modelKey = "geminiModel"
    static let llmProviderKey = "llmProvider"
    static let deepseekAPIKeyKey = "deepseekAPIKey"
    static let deepseekModelKey = "deepseekModel"
    static let anthropicAPIKeyKey = "anthropicAPIKey"
    static let anthropicModelKey = "anthropicModel"
    static let notesPromptKey = "notesPromptTemplate"
    static let transcriptPromptKey = "transcriptPromptTemplate"
    static let noteTemplatesKey = "noteTemplates"

    /// Providers with a working integration; anything else stored under
    /// `llmProviderKey` (e.g. a "coming soon" tab) resolves to Gemini.
    static let supportedProviders = ["Gemini", "Anthropic", "DeepSeek"]

    static var currentProvider: String {
        let stored = UserDefaults.standard.string(forKey: llmProviderKey) ?? "Gemini"
        return supportedProviders.contains(stored) ? stored : "Gemini"
    }

    /// The UserDefaults key holding a provider's API key.
    static func apiKeyStorageKey(for provider: String) -> String {
        switch provider {
        case "Anthropic": return anthropicAPIKeyKey
        case "DeepSeek": return deepseekAPIKeyKey
        default: return apiKeyKey
        }
    }

    /// A provider's saved API key, trimmed.
    static func storedAPIKey(for provider: String) -> String {
        (UserDefaults.standard.string(forKey: apiKeyStorageKey(for: provider)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The UserDefaults key holding a provider's selected note-generation model.
    /// Mirrors `apiKeyStorageKey(for:)` so provider-keyed storage lives in one
    /// place rather than being re-spelled at each call site.
    static func modelStorageKey(for provider: String) -> String {
        switch provider {
        case "Anthropic": return anthropicModelKey
        case "DeepSeek": return deepseekModelKey
        default: return modelKey
        }
    }

    /// Every model a provider can generate notes with — the one place the
    /// per-provider catalogs below are keyed by provider name.
    static func availableModels(for provider: String) -> [String] {
        switch provider {
        case "Anthropic": return availableAnthropicModels
        case "DeepSeek": return availableDeepSeekModels
        default: return Self.availableModels
        }
    }

    /// Selecting a model is also selecting its provider. The quick-settings
    /// panel on the floating bar lists every configured provider's models as one
    /// menu, so picking one has to move `llmProvider` with it — otherwise the
    /// choice would be stored but never used.
    static func selectModel(_ model: String, provider: String) {
        UserDefaults.standard.set(provider, forKey: llmProviderKey)
        UserDefaults.standard.set(model, forKey: modelStorageKey(for: provider))
    }

    /// The model a provider will actually use, with stale/unknown stored
    /// values resolved to something currently served.
    static func resolvedModel(for provider: String) -> String {
        switch provider {
        case "Anthropic":
            return resolveAnthropicModel(string(forKey: anthropicModelKey, default: defaultAnthropicModel))
        case "DeepSeek":
            return resolveDeepSeekModel(string(forKey: deepseekModelKey, default: defaultDeepSeekModel))
        default:
            return resolveModel(string(forKey: modelKey, default: defaultModel))
        }
    }

    static let transcriptionEngineKey = "transcriptionEngine"

    enum TranscriptionEngine: String, CaseIterable {
        case gemini
        case appleAdvanced
        case appleBasic

        var displayName: String {
            switch self {
            case .gemini: return "Gemini (Cloud)"
            case .appleAdvanced: return "On-Device (Advanced)"
            case .appleBasic: return "On-Device (Basic)"
            }
        }
    }

    static var currentTranscriptionEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: transcriptionEngineKey) ?? "") ?? .gemini
    }

    /// The engine that will actually run: Advanced silently degrades to Basic
    /// on Macs where the macOS 26 SpeechAnalyzer API isn't available.
    static var resolvedTranscriptionEngine: TranscriptionEngine {
        let engine = currentTranscriptionEngine
        if engine == .appleAdvanced && !AppleTranscriber.advancedAvailable { return .appleBasic }
        return engine
    }

    /// Providers with an API key saved — the only valid choices for the
    /// Default Provider picker in Settings.
    static var configuredProviders: [String] {
        supportedProviders.filter { !storedAPIKey(for: $0).isEmpty }
    }

    // deepseek-v4-flash is the fast/cheap default; deepseek-v4-pro is the
    // heavier variant — overkill for note synthesis but selectable.
    // (Current lineup per api-docs.deepseek.com as of Aug 2026; the old
    // deepseek-chat / deepseek-reasoner names are no longer documented.)
    static let defaultDeepSeekModel = "deepseek-v4-flash"
    static let availableDeepSeekModels = ["deepseek-v4-flash", "deepseek-v4-pro"]

    /// Maps retired DeepSeek model names a stale stored setting might hold.
    private static let retiredDeepSeekRemap: [String: String] = [
        "deepseek-chat": "deepseek-v4-flash",
        "deepseek-reasoner": "deepseek-v4-pro",
    ]

    // Haiku is the cheapest/fastest tier and the default, matching the other
    // providers; Sonnet and Opus are selectable when notes need more depth.
    // (Model IDs are complete as written — they never take a date suffix.)
    static let defaultAnthropicModel = "claude-haiku-4-5"
    static let availableAnthropicModels = ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-5"]

    static func resolveAnthropicModel(_ name: String) -> String {
        availableAnthropicModels.contains(name) ? name : defaultAnthropicModel
    }

    static func resolveDeepSeekModel(_ name: String) -> String {
        if let remapped = retiredDeepSeekRemap[name] { return remapped }
        return availableDeepSeekModels.contains(name) ? name : defaultDeepSeekModel
    }

    // gemini-3.5-flash is pinned as the default because the rolling gemini-flash-latest
    // alias (currently gemini-3.6-flash) 500s on audio input as of Aug 2026.
    static let defaultModel = "gemini-3.5-flash"
    static let availableModels = ["gemini-3.5-flash", "gemini-flash-latest", "gemini-pro-latest", "gemini-3-flash-preview"]

    /// Transcription always runs on the cheapest flash tier, whatever model is
    /// picked for note generation: speech-to-text is the token-heavy step (a
    /// long meeting is a lot of audio input), the flash models handle it well,
    /// and pro-tier rates buy nothing here. It's also the tier verified to work
    /// with audio at all — see the model-landscape note above.
    static let transcriptionModel = "gemini-3.5-flash"

    /// Tried in order when the selected model fails with a server error, a
    /// retired-model 404, or a quota 429.
    static let fallbackModels = ["gemini-3.5-flash", "gemini-3-flash-preview", "gemini-flash-latest"]

    /// Models Google has retired for new users; map them to their rolling-alias successors
    /// so a stale stored setting can never 404 the way gemini-2.5-flash did.
    private static let retiredModelRemap: [String: String] = [
        "gemini-2.5-flash": "gemini-3.5-flash",
        "gemini-2.5-flash-lite": "gemini-flash-lite-latest",
        "gemini-2.5-pro": "gemini-pro-latest",
        "gemini-2.0-flash": "gemini-3.5-flash",
        "gemini-1.5-flash": "gemini-3.5-flash",
        "gemini-1.5-pro": "gemini-pro-latest",
    ]

    static func resolveModel(_ name: String) -> String {
        retiredModelRemap[name] ?? name
    }

    static let defaultTranscriptPrompt = """
    Transcribe this meeting recording completely and verbatim.
    - The person who recorded this meeting is {{user_name}}. Their voice is the one captured \
    directly by the microphone (typically the clearest audio). Label their turns with their \
    name exactly as given — do not guess a different name for them.
    - Identify each other distinct speaker. If a speaker's name is mentioned in the audio, use it; \
    otherwise label them Speaker 1, Speaker 2, and so on. Be consistent throughout.
    - Format each turn on its own line as: **<Speaker>** [mm:ss]: <what they said>
    - Keep the transcript faithful. Include every utterance, but you may drop pure filler sounds ("um", "uh").
    - Output plain Markdown only — no code fences, no commentary before or after the transcript.
    """

    static let defaultNotesPrompt = """
    You are an expert meeting-notes assistant. You will receive the full transcript of a meeting \
    plus the user's own sparse manual notes. The manual notes signal what the user found important — \
    treat them as the contextual anchor for everything you write.

    Rules:
    1. Include every line of the user's manual notes, correcting only spelling and grammar mistakes. \
    Beyond those corrections, do not change their wording, meaning, or order.
    2. Expand around those anchors: add context, names, numbers, decisions, and action items \
    drawn from the transcript.
    3. Organize the result as clean Markdown, using the sections named under "Note type" below. \
    Omit a section entirely if there is nothing for it. Weave the manual note lines into whichever \
    sections they fit best. Add any sections as you see fit, if there is a topic that was discussed \
    that does not fit into these sections.
    4. Length and depth: {{verbosity}}
    5. Be factual. Only use information found in the transcript or the manual notes. Never invent \
    facts, and never pad with filler.
    6. Output pure Markdown with no code fences and no preamble. Do NOT repeat the meeting \
    title or date anywhere — the app already displays them above the notes. Begin directly \
    with the first section heading.
    7. Formatting: use "-" for every bullet (never "*" or "+"). Use **bold** only sparingly \
    for names and key terms. Never use italics, and never use a bare "*" anywhere in prose.

    Meeting title: {{title}}
    Meeting date: {{date}}
    Note type:
    {{template_context}}
    The user (the person whose notes these are) is named {{user_name}} — refer to them by this \
    name, spelled exactly this way, wherever they come up.

    User's manual notes:
    {{manual_notes}}

    Full transcript:
    {{transcript}}
    """

    static let verbosityLevelNames = ["More Succinct", "Succinct", "Balanced", "Detailed", "More Detailed"]
    static let defaultVerbosity = 2

    static func verbosityInstruction(level: Int) -> String {
        switch level {
        case 0:
            return "Extremely succinct. Terse bullet fragments only; capture just the handful of points that truly matter. Keep the whole output under roughly 120 words."
        case 1:
            return "Very succinct. Short bullets covering only key points, decisions, and action items, with minimal context."
        case 3:
            return "Detailed. Cover all significant discussion points, each with a brief line of supporting context from the transcript."
        case 4:
            return "Comprehensive. Thoroughly cover every topic with supporting details, figures, and context from the transcript; longer output is fine."
        default:
            return "Succinct and to the point. Crisp, short bullets with no filler; include every important point, decision, and action item, but keep each one brief."
        }
    }

    static var currentVerbosity: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: verbosityKey) != nil else { return defaultVerbosity }
        return min(max(defaults.integer(forKey: verbosityKey), 0), 4)
    }

    static func applyAppearance() {
        switch UserDefaults.standard.string(forKey: appearanceKey) ?? "auto" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    static func string(forKey key: String, default defaultValue: String) -> String {
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultValue : stored
    }
}
