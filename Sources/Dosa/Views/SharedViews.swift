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

/// The recording bar's silhouette: a wide plinth with a narrower box centred on
/// top of it, the two joined by concave fillets. Collapsed, that box is a small
/// half-oval pull-tab; expanded, it is the quick-settings panel — and because
/// this is *one* shape with animatable dimensions, the tab morphs into the panel
/// rather than a second surface fading in on top of the bar.
///
/// Drawn as a single continuous outline rather than two overlapping rounded
/// rectangles. Overlapping subpaths would union correctly under a non-zero fill,
/// but `FloatingChrome`'s pre-26 branch *strokes* the shape, and a stroke traces
/// the submerged edges too — printing a hairline seam straight across the
/// junction. One outline also gives Liquid Glass a single unbroken edge to
/// highlight, which is what makes the panel read as part of the bar.
///
/// This is still one glass surface, so §9c's "add a `GlassEffectContainer` if two
/// glass shapes ever sit side by side" does not apply.
struct BarPedestalShape: InsettableShape {
    /// Width of the box on top — the pull-tab's, or the open panel's.
    var topWidth: CGFloat
    /// How far that box rises above the bar. At zero this collapses to a plain
    /// rounded rectangle, i.e. exactly the bar as it was before the tab existed.
    var topHeight: CGFloat
    var topCornerRadius: CGFloat = 12
    var barCornerRadius: CGFloat = 26
    /// Radius of the concave flare where the top box meets the bar's top edge.
    var jointRadius: CGFloat = 10
    var insetAmount: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topWidth, topHeight) }
        set {
            topWidth = newValue.first
            topHeight = newValue.second
        }
    }

    func inset(by amount: CGFloat) -> BarPedestalShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let inner = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard inner.width > 0, inner.height > 0 else { return Path() }

        // The seam sits at an absolute offset from the frame's top edge, so the
        // top box loses height to an inset only at its own top.
        let th = topHeight - insetAmount
        let barSide = max(inner.height - max(th, 0), 0)
        let r = max(min(barCornerRadius - insetAmount, inner.width / 2, barSide / 2), 0)

        func plainBar() -> Path {
            Path(roundedRect: inner, cornerRadius: r, style: .continuous)
        }

        // An inset stroke sits inside the fillet, so its concave radius grows.
        let flare = max(jointRadius + insetAmount, 0)
        // Both shoulders need a straight run of the bar's top edge to flare onto,
        // so the top box can never reach into the bar's own corners. The bar is
        // ~430 pt at its narrowest and the panel is 300, so this only bites in
        // degenerate layouts — but it keeps the arcs from folding back on
        // themselves if it ever does.
        let widest = inner.width - 2 * (r + flare)
        let tw = min(topWidth - 2 * insetAmount, widest)
        guard th > 0.5, widest > 0, tw > 0 else { return plainBar() }

        let tr = max(min(topCornerRadius - insetAmount, tw / 2, th), 0)
        let joint = max(min(flare, th - tr), 0)

        let x1 = inner.midX - tw / 2
        let x2 = inner.midX + tw / 2
        let top = inner.minY
        let seam = inner.minY + th
        let bottom = inner.maxY
        let left = inner.minX
        let right = inner.maxX

        // Corner-by-corner with tangent arcs: each call rounds the corner at
        // `tangent1End` on the way to `tangent2End`. At the two shoulders the
        // interior angle is reflex, so the same call produces the concave flare.
        var path = Path()
        path.move(to: CGPoint(x: inner.midX, y: bottom))
        path.addArc(tangent1End: CGPoint(x: left, y: bottom),
                    tangent2End: CGPoint(x: left, y: seam), radius: r)
        path.addArc(tangent1End: CGPoint(x: left, y: seam),
                    tangent2End: CGPoint(x: x1, y: seam), radius: r)
        path.addArc(tangent1End: CGPoint(x: x1, y: seam),
                    tangent2End: CGPoint(x: x1, y: top), radius: joint)
        path.addArc(tangent1End: CGPoint(x: x1, y: top),
                    tangent2End: CGPoint(x: x2, y: top), radius: tr)
        path.addArc(tangent1End: CGPoint(x: x2, y: top),
                    tangent2End: CGPoint(x: x2, y: seam), radius: tr)
        path.addArc(tangent1End: CGPoint(x: x2, y: seam),
                    tangent2End: CGPoint(x: right, y: seam), radius: joint)
        path.addArc(tangent1End: CGPoint(x: right, y: seam),
                    tangent2End: CGPoint(x: right, y: bottom), radius: r)
        path.addArc(tangent1End: CGPoint(x: right, y: bottom),
                    tangent2End: CGPoint(x: inner.midX, y: bottom), radius: r)
        path.closeSubpath()
        return path
    }
}

/// Height of the floating bar's top box (the pull-tab, plus the quick-settings
/// panel when it is open), measured rather than hard-coded so `BarPedestalShape`
/// carves the silhouette at the size the content actually laid out at.
struct BarTopBoxHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The 5-stop Notes Style control. It lives here because it renders in two
/// places — the Settings form and the floating bar's quick-settings panel — and
/// being literally the same control in both is the point.
struct NotesStyleSlider: View {
    @Binding var level: Int

    var body: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { Double(level) },
                    set: { level = Int($0.rounded()) }
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
