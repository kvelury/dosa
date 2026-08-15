import SwiftUI

/// Shown at the top of every detail-pane page until the user has a name and
/// an LLM API key configured — both are required before recording/notes are
/// actually usable, but nothing else in the app enforces that up front.
struct SetupBanner: View {
    @AppStorage(AppSettings.userNameKey) private var userName = ""
    @AppStorage(AppSettings.apiKeyKey) private var apiKey = ""
    @AppStorage(AppSettings.deepseekAPIKeyKey) private var deepseekAPIKey = ""
    @AppStorage(AppSettings.anthropicAPIKeyKey) private var anthropicAPIKey = ""
    @AppStorage(AppSettings.llmProviderKey) private var llmProvider = "Gemini"
    let onOpenSettings: () -> Void

    private var message: String? {
        setupBannerMessage(
            userName: userName,
            apiKey: apiKey,
            deepseekAPIKey: deepseekAPIKey,
            anthropicAPIKey: anthropicAPIKey,
            llmProvider: llmProvider
        )
    }

    var body: some View {
        if let message {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.current.highlightColor)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.current.accentColor)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.current.cardFillColor)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }
}

/// Applies the setup banner as a top inset only when it has something to say.
/// An empty `.safeAreaInset` still reserves a strip at the top of the detail
/// pane on some macOS versions, which showed up as a white bar on Welcome.
struct SetupBannerInset: ViewModifier {
    let onOpenSettings: () -> Void
    @AppStorage(AppSettings.userNameKey) private var userName = ""
    @AppStorage(AppSettings.apiKeyKey) private var apiKey = ""
    @AppStorage(AppSettings.deepseekAPIKeyKey) private var deepseekAPIKey = ""
    @AppStorage(AppSettings.anthropicAPIKeyKey) private var anthropicAPIKey = ""
    @AppStorage(AppSettings.llmProviderKey) private var llmProvider = "Gemini"

    private var needed: Bool {
        setupBannerMessage(
            userName: userName,
            apiKey: apiKey,
            deepseekAPIKey: deepseekAPIKey,
            anthropicAPIKey: anthropicAPIKey,
            llmProvider: llmProvider
        ) != nil
    }

    func body(content: Content) -> some View {
        if needed {
            content.safeAreaInset(edge: .top, spacing: 0) {
                SetupBanner(onOpenSettings: onOpenSettings)
            }
        } else {
            content
        }
    }
}

private func setupBannerMessage(
    userName: String,
    apiKey: String,
    deepseekAPIKey: String,
    anthropicAPIKey: String,
    llmProvider: String
) -> String? {
    let missingName = userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let provider = AppSettings.supportedProviders.contains(llmProvider) ? llmProvider : "Gemini"
    let providerKey: String
    switch provider {
    case "Anthropic": providerKey = anthropicAPIKey
    case "DeepSeek": providerKey = deepseekAPIKey
    default: providerKey = apiKey
    }
    let missingAPIKey = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    switch (missingName, missingAPIKey) {
    case (true, true):
        return "Finish setting up Dosa — add your name and an LLM provider API key in Settings."
    case (true, false):
        return "Add your name in Settings so Dosa can label your voice correctly."
    case (false, true):
        return "Add an LLM provider API key in Settings to enable transcription and note generation."
    case (false, false):
        return nil
    }
}

/// Chrome for the overlays that float above the editor — the recording bar, the
/// actions pill, the toast. macOS 26 draws them in Liquid Glass; earlier releases
/// keep the material + hairline + shadow recipe those overlays shipped with.
///
/// `canImport(FoundationModels)` is how the app probes for a macOS 26 SDK at
/// compile time, same as `AppleTranscriber.advancedAvailable`, so a binary built
/// against an older SDK still compiles and takes the fallback.
struct FloatingChrome<S: InsettableShape>: ViewModifier {
    let shape: S
    /// Glass that responds to hover and press. Right for a control that is itself
    /// one button, wrong for a container that holds its own controls.
    var interactive: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            material(content)
        }
        #else
        material(content)
        #endif
    }

    private func material(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}

extension View {
    func floatingChrome<S: InsettableShape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(FloatingChrome(shape: shape, interactive: interactive))
    }
}

/// Live audio-level bars shown in the floating bar while recording, so the
/// user can see that real audio is being picked up.
struct RecordingWaveformView: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.red)
                    .frame(width: 3, height: 4 + CGFloat(min(max(level, 0), 1)) * 16)
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}

/// Shown in the detail pane when multiple sidebar notes are selected.
struct MultiSelectionView: View {
    let count: Int

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("\(count) notes selected")
                .font(.title2.weight(.semibold))
            Text("Right-click the selection in the sidebar to pin, move, or delete these notes together, or drag them into a folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.current.editorBackgroundColor)
    }
}

/// Error dialog with a friendly summary and a collapsed, expandable section
/// containing the raw API/server response for debugging.
struct ErrorDialogView: View {
    @Environment(\.dismiss) private var dismiss
    let message: String
    let detail: String?

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text("Something went wrong")
                    .font(.headline)
                Spacer()
            }

            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let detail, !detail.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    ScrollView {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
                } label: {
                    Text(showDetails ? "Hide technical details" : "Show technical details")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation {
                                showDetails.toggle()
                            }
                        }
                }
            }

            HStack {
                Spacer()
                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
