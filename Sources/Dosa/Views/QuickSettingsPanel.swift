import SwiftUI

/// The two settings that get changed most — which model writes the notes, and
/// how detailed those notes should be — surfaced on the floating bar so they can
/// be set right before pressing Generate, instead of through the Settings sheet
/// (which is modal, and whose dismissal rebuilds the whole view tree).
///
/// Everything here writes the same UserDefaults keys Settings writes, through
/// `@AppStorage`, so the two stay in lockstep in both directions.
struct QuickSettingsPanel: View {
    @AppStorage(AppSettings.verbosityKey) private var verbosity = AppSettings.defaultVerbosity
    @AppStorage(AppSettings.llmProviderKey) private var llmProvider = "Gemini"

    // The model keys are bound so the label re-renders when a selection lands.
    // The *writes* go through AppSettings.selectModel, which also moves
    // llmProvider — picking a model is picking its provider.
    @AppStorage(AppSettings.modelKey) private var geminiModel = AppSettings.defaultModel
    @AppStorage(AppSettings.anthropicModelKey) private var anthropicModel = AppSettings.defaultAnthropicModel
    @AppStorage(AppSettings.deepseekModelKey) private var deepseekModel = AppSettings.defaultDeepSeekModel

    // A saved API key is what puts a provider in the menu. Bound here, rather
    // than read off AppSettings.configuredProviders, so the menu updates live
    // when a key is added or cleared in Settings — same reason SettingsView
    // keeps its own copy of this derivation.
    @AppStorage(AppSettings.apiKeyKey) private var geminiKey = ""
    @AppStorage(AppSettings.anthropicAPIKeyKey) private var anthropicKey = ""
    @AppStorage(AppSettings.deepseekAPIKeyKey) private var deepseekKey = ""

    private var configuredProviders: [String] {
        AppSettings.supportedProviders.filter { provider in
            !storedKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func storedKey(for provider: String) -> String {
        switch provider {
        case "Anthropic": return anthropicKey
        case "DeepSeek": return deepseekKey
        default: return geminiKey
        }
    }

    private func storedModel(for provider: String) -> String {
        switch provider {
        case "Anthropic": return AppSettings.resolveAnthropicModel(anthropicModel)
        case "DeepSeek": return AppSettings.resolveDeepSeekModel(deepseekModel)
        default: return AppSettings.resolveModel(geminiModel)
        }
    }

    private var activeProvider: String {
        AppSettings.supportedProviders.contains(llmProvider) ? llmProvider : "Gemini"
    }

    private var activeModel: String { storedModel(for: activeProvider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            modelRow
            notesStyleRow
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var modelRow: some View {
        HStack(spacing: 10) {
            Text("Model")
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if configuredProviders.isEmpty {
                Text("No LLM configured")
                    .appFont(size: 12)
                    .foregroundStyle(.tertiary)
            } else {
                modelMenu
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            // One section per configured provider, so the flat list still reads
            // as "these are Claude's, those are Gemini's".
            ForEach(configuredProviders, id: \.self) { provider in
                Section(provider) {
                    ForEach(AppSettings.availableModels(for: provider), id: \.self) { model in
                        Button {
                            AppSettings.selectModel(model, provider: provider)
                        } label: {
                            if provider == activeProvider && model == activeModel {
                                Label(model, systemImage: "checkmark")
                            } else {
                                Text(model)
                            }
                        }
                    }
                }
            }
        } label: {
            // Sized with resizable frames, not a font: a Menu's own control
            // metrics win over its label's font. Padding lives inside the label
            // so the whole chip opens the menu, not just the glyph.
            HStack(spacing: 5) {
                Text(activeModel)
                    .appFont(size: 12, weight: .medium)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 8, height: 8)
                    .fontWeight(.regular)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(Capsule().fill(.quaternary.opacity(0.4)))
        .help("Model used to generate notes. Picking one also makes its provider the default.")
    }

    private var notesStyleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes Style: \(AppSettings.verbosityLevelNames[min(max(verbosity, 0), 4)])")
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
            NotesStyleSlider(level: $verbosity)
                .controlSize(.small)
        }
    }
}
