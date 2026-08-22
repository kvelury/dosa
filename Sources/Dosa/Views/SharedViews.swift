import SwiftUI
import AppKit

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
                    .appFont(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.current.accentColor)
                    .controlSize(.small)
                    .appFont(.subheadline)
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

struct CalendarSetupBanner: View {
    @EnvironmentObject private var calendar: GoogleCalendarManager
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .foregroundStyle(Theme.current.highlightColor)
            Text("Connect Google Calendar in Settings to see upcoming meetings on your home screen.")
                .appFont(.callout)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .tint(Theme.current.accentColor)
                .controlSize(.small)
                .appFont(.subheadline)
            Button("Dismiss") {
                calendar.dismissSetupBanner()
            }
            .controlSize(.small)
            .appFont(.subheadline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.current.cardFillColor)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct CalendarSetupBannerInset: ViewModifier {
    let isHomeVisible: Bool
    let onOpenSettings: () -> Void
    @EnvironmentObject private var calendar: GoogleCalendarManager

    private var needed: Bool {
        isHomeVisible && calendar.showSetupBanner
    }

    func body(content: Content) -> some View {
        if needed {
            content.safeAreaInset(edge: .top, spacing: 0) {
                CalendarSetupBanner(onOpenSettings: onOpenSettings)
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
/// recording-away toast, and the transient event toast. macOS 26 draws them in
/// Liquid Glass; earlier releases keep the material + hairline + shadow recipe
/// those overlays shipped with.
///
/// Only for glass the app draws *over content*. Toolbar items get the system's own
/// Liquid Glass and must not be given this as well — see §9c.
///
/// `canImport(FoundationModels)` is how the app probes for a macOS 26 SDK at
/// compile time, same as `AppleTranscriber.advancedAvailable`, so a binary built
/// against an older SDK still compiles and takes the fallback.
struct FloatingChrome<S: InsettableShape>: ViewModifier {
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // Never `.interactive()`. That is for glass which is itself one
            // button; the surfaces left here are containers holding their own
            // controls, and it would light the whole thing up whenever the
            // pointer neared any of them. The one control that did want it —
            // the ⋯ pill — is a toolbar item now and gets the system's.
            content.glassEffect(.regular, in: shape)
        } else {
            material(content)
        }
        #else
        material(content)
        #endif
    }

    private func material(_ content: Content) -> some View {
        // Reduce Transparency: an opaque card fill instead of translucent
        // material, both because that's what the setting asks for and because
        // text contrast against `.regularMaterial` is unmeasurable — its
        // backdrop is whatever happens to be behind the window.
        let base = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? AnyShapeStyle(Theme.current.cardFillColor)
            : AnyShapeStyle(.regularMaterial)
        return content
            .background(base, in: shape)
            .overlay(shape.strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}

extension View {
    func floatingChrome<S: InsettableShape>(in shape: S) -> some View {
        modifier(FloatingChrome(shape: shape))
    }
}

/// The back arrow in the toolbar's leading region that returns the detail pane to
/// Welcome — the same thing ⌘W "Close Note" does. Deselecting is already what ⌘W
/// and a click on empty sidebar space do; neither is discoverable from inside an
/// open note.
///
/// It is a `ToolbarItem`, not an overlay, because both places it has to appear —
/// beside the floating sidebar toggle when the sidebar is collapsed, at the detail
/// column's leading edge when it is open — are in the titlebar strip, and the app
/// deliberately cannot tell those two states apart (§9b bans a `columnVisibility`
/// binding and `check-window-chrome.sh` enforces it). The toolbar tracks the split
/// for us, which is the whole reason this works. See §9b.
///
/// No `floatingChrome` and no `buttonStyle`: macOS 26 gives toolbar items their own
/// Liquid Glass background — the sidebar toggle's pill *is* that treatment — so
/// drawing our own would be glass-on-glass (§9c). The `ToolbarSpacer` is only there
/// to keep the two from being absorbed into one segmented capsule.
///
/// The availability check has to sit out here in the `ViewBuilder` rather than
/// inside the `.toolbar { }` closure: `ToolbarContentBuilder.buildLimitedAvailability`
/// is itself macOS 14.5+, and `Package.swift` targets 14.0, so an `if #available`
/// *inside* the toolbar closure resolves to the obsoleted overload — the one whose
/// message is "this code may crash on earlier versions of the OS". `ViewBuilder`'s
/// equivalent has no such floor.
struct BackToWelcomeToolbar: ViewModifier {
    let isVisible: Bool
    /// Passed in rather than read from `Theme.current` inside, so a theme change
    /// is an actual value change on this modifier. The toolbar is applied after
    /// `ContentView`'s `.id(themeRefreshTick)`, deliberately — re-keying it would
    /// tear the item out of the NSToolbar and put it back on every refresh — so
    /// it does not get the id-based redraw the rest of the detail pane gets.
    let tint: Color
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            content.toolbar {
                if isVisible {
                    // A fixed spacer is a break between Liquid Glass groups, so
                    // this reads as its own pill beside the toggle instead of a
                    // second compartment welded onto it.
                    ToolbarSpacer(.fixed, placement: .navigation)
                    ToolbarItem(placement: .navigation) { button }
                }
            }
        } else {
            plain(content)
        }
        #else
        plain(content)
        #endif
    }

    private func plain(_ content: Content) -> some View {
        content.toolbar {
            if isVisible {
                ToolbarItem(placement: .navigation) { button }
            }
        }
    }

    /// No font, frame, or image scale: the toolbar's own control metrics are what
    /// match this to the system sidebar toggle, and overriding them is exactly
    /// what would break the match. Color is the one exception — the glyph takes
    /// the theme accent, set explicitly because `ContentView`'s `.tint` does not
    /// reach the window toolbar (it hosts items outside the content hierarchy).
    private var button: some View {
        Button(action: action) {
            Label("Back to home", systemImage: "chevron.backward")
        }
        .labelStyle(.iconOnly)
        .foregroundStyle(tint)
        .help("Back to home (⌘W)")
    }
}

extension View {
    func backToWelcomeToolbar(isVisible: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        modifier(BackToWelcomeToolbar(isVisible: isVisible, tint: tint, action: action))
    }
}

/// Puts one control at the **trailing** end of the window toolbar.
///
/// `.primaryAction` alone does not do this. In a `NavigationSplitView` detail
/// column the items pack against the *leading* edge of the detail's toolbar
/// section — which put the ⋯ menu immediately beside the back arrow — because
/// nothing pushes them outward. A flexible spacer is what sends it to the far
/// side, and it has to be a toolbar spacer: padding or an offset on the item
/// resizes or shifts the contents of its glass pill instead of moving the pill.
///
/// Same availability hoist as `BackToWelcomeToolbar`, for the same reason: the
/// branch cannot live inside the `.toolbar { }` closure.
struct TrailingToolbarItem<Item: View>: ViewModifier {
    let item: () -> Item

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            content.toolbar {
                ToolbarSpacer(.flexible, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) { item() }
            }
        } else {
            spacedGroup(content)
        }
        #else
        spacedGroup(content)
        #endif
    }

    /// Pre-26 has no `ToolbarSpacer`, but a `Spacer` inside a `ToolbarItemGroup`
    /// expands the same way.
    private func spacedGroup(_ content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Spacer()
                item()
            }
        }
    }
}

extension View {
    func trailingToolbarItem<Item: View>(@ViewBuilder _ item: @escaping () -> Item) -> some View {
        modifier(TrailingToolbarItem(item: item))
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
            .accessibilityLabel("Notes style")
            .accessibilityValue(AppSettings.verbosityLevelNames[min(max(level, 0), 4)])
            .frame(maxWidth: .infinity)
            HStack {
                Text("More Succinct")
                Spacer()
                Text("Balanced")
                Spacer()
                Text("More Detailed")
            }
            .appFont(.caption)
            .foregroundStyle(Theme.secondaryTextColor)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Persistent toast at the top of the detail pane whenever a recording is running
/// and the pane is showing anything other than that recording's own note. ⌘R can
/// start a capture from anywhere, and every other on-screen trace lives in the
/// floating bar, which unmounts the moment you leave the note. Not dismissible —
/// dismissing it would recreate the problem. The whole capsule is the hit target
/// back to the recording's note.
struct RecordingAwayToast: View {
    let elapsed: TimeInterval
    let ringPhase: Int
    let onGoBack: () -> Void

    private var shape: Capsule { Capsule() }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
            HStack(spacing: 0) {
                Text("Recording")
                AnimatedEllipsis(ringPhase: ringPhase)
            }
            Text(TimeFormatting.clock(elapsed))
                .appMonoFont(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
        }
        .appFont(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .floatingChrome(in: shape)
        .overlay(shape.strokeBorder(.red, lineWidth: 1.5))
        .fixedSize()
        .contentShape(shape)
        .onTapGesture(perform: onGoBack)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording, \(TimeFormatting.spoken(elapsed)). Go back to note.")
        .accessibilityAddTraits([.isButton, .updatesFrequently])
    }
}

/// Three dots whose opacity follows `AudioRecorder.ringPhase`, so the ellipsis
/// animates without its own timer and stops the instant recording does.
/// All three glyphs stay laid out; only opacity changes, so the clock never shifts.
private struct AnimatedEllipsis: View {
    let ringPhase: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 24 ring frames ÷ 8 = three dot states per ring revolution, ~0.72 s each.
    private var lit: Int { reduceMotion ? 3 : (ringPhase / 8) % 3 + 1 }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { i in
                // 0.45, not 0.15 — the unlit floor still needs to read as
                // present, not effectively invisible, against any background.
                Text(".").opacity(i < lit ? 1 : 0.45) // contrast-ok: bounded floor, not a contrast regression
            }
        }
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
        .accessibilityHidden(true)
    }
}

/// Shown in the detail pane when multiple sidebar notes are selected.
struct MultiSelectionView: View {
    let count: Int

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44))
                .foregroundStyle(Theme.secondaryTextColor)
                .accessibilityHidden(true)
            Text("\(count) notes selected")
                .appFont(.title2, weight: .semibold)
            Text("Right-click the selection in the sidebar to pin, move, or delete these notes together, or drag them into a folder.")
                .appFont(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
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
                    .foregroundStyle(Theme.current.warningTextColor)
                    .accessibilityHidden(true)
                Text("Something went wrong")
                    .appFont(.headline)
                Spacer()
            }

            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let detail, !detail.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    ScrollView {
                        Text(detail)
                            .appMonoFont(size: 11)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
                } label: {
                    // A real Button, not a tap-gesture-only label, so this is
                    // reachable by keyboard/VoiceOver as well as by mouse.
                    Button {
                        withAnimation {
                            showDetails.toggle()
                        }
                    } label: {
                        Text(showDetails ? "Hide technical details" : "Show technical details")
                            .appFont(.callout)
                            .foregroundStyle(Theme.secondaryTextColor)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(.isButton)
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
        .appFontScope()
    }
}

/// The chrome every editor-header popup shares — the sparkle pill's hover card, the date
/// calendar, the meeting card, the recording actions. Opaque theme fill rather than a
/// material: these cards sit directly over editor text, where a translucent backdrop makes
/// contrast unmeasurable (the same reason `FloatingChrome` swaps to `cardFillColor` under
/// Reduce Transparency). No shadow and no arrow — this is deliberately flatter than the
/// floating bar's chrome, which is a different surface with a different job.
struct PillPopoverCard: ViewModifier {
    var horizontal: CGFloat = 10
    var vertical: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.current.cardFillColor))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

extension View {
    func pillPopoverCard(horizontal: CGFloat = 10, vertical: CGFloat = 6) -> some View {
        modifier(PillPopoverCard(horizontal: horizontal, vertical: vertical))
    }
}

/// The capsule chrome the editor-header chips share — `EditorPill`'s own capsule and the
/// view-mode switcher's outer track. Companion to `PillPopoverCard`, which is the same
/// palette applied to the popups those chips open.
struct PillCapsule: ViewModifier {
    /// Accent wash over the fill, for hover. 0.10 is the established pill hover tint.
    var highlight: Double = 0

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(Theme.current.cardFillColor))
            .overlay(Capsule().strokeBorder(.quaternary))
            .overlay(Capsule().fill(Theme.current.accentColor.opacity(highlight)))
            .contentShape(Capsule())
    }
}

extension View {
    func pillCapsule(highlight: Double = 0) -> some View {
        modifier(PillCapsule(highlight: highlight))
    }
}

/// A themed capsule chip matching the homepage meeting cards' fill and hairline
/// border. Pass `action` to make it clickable with a hover cue; pass `info` to
/// reveal a themed card below it on hover; pass `isPanelPresented` for a
/// click-toggled panel in that same card chrome; omit all three for a static chip.
struct EditorPill<PillLabel: View, Panel: View>: View {
    var action: (() -> Void)?
    var info: String?
    var isPanelPresented: Binding<Bool>?
    @ViewBuilder var label: PillLabel
    @ViewBuilder var panel: Panel

    @State private var isHovering = false
    @FocusState private var panelFocused: Bool

    private var tracksHover: Bool { action != nil || info != nil || isPanelPresented != nil }
    private var isPanelOpen: Bool { isPanelPresented?.wrappedValue == true }

    var body: some View {
        Group {
            if isPanelPresented != nil {
                Button {
                    isPanelPresented?.wrappedValue.toggle()
                } label: {
                    content
                }
                .buttonStyle(.plain)
            } else if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .overlay(alignment: .topLeading) {
            if let info, isHovering {
                Text(info)
                    .appFont(size: 12)
                    .foregroundStyle(Theme.secondaryTextColor)
                    .fixedSize()
                    .pillPopoverCard()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .offset(y: 34)
            } else if let isPanelPresented, isPanelPresented.wrappedValue {
                panel
                    .background(PanelMarker())
                    .pillPopoverCard(horizontal: 12, vertical: 10)
                    .onExitCommand { isPanelPresented.wrappedValue = false }
                    .focused($panelFocused)
                    .background(ClickOutsideCatcher { isPanelPresented.wrappedValue = false })
                    .transition(.opacity)
                    .offset(y: 34)
                    .onAppear { panelFocused = true }
            }
        }
        .onExitCommand {
            isPanelPresented?.wrappedValue = false
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isPanelOpen)
        .background {
            if isPanelPresented != nil {
                PanelMarker()
            }
        }
        .applyIf(tracksHover) { view in
            view.onHover { hovering in
                isHovering = hovering
                guard action != nil || isPanelPresented != nil else { return }
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }

    private var content: some View {
        label
            .appFont(size: 13)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .pillCapsule(highlight: isHovering ? 0.10 : 0)
    }
}

extension EditorPill where Panel == EmptyView {
    init(action: (() -> Void)? = nil, info: String? = nil, @ViewBuilder label: () -> PillLabel) {
        self.action = action
        self.info = info
        self.isPanelPresented = nil
        self.label = label()
        self.panel = EmptyView()
    }
}

extension EditorPill {
    init(
        isPanelPresented: Binding<Bool>,
        @ViewBuilder label: () -> PillLabel,
        @ViewBuilder panel: () -> Panel
    ) {
        self.action = nil
        self.info = nil
        self.isPanelPresented = isPanelPresented
        self.label = label()
        self.panel = panel()
    }
}

/// The header's view-mode switcher, in the same idiom as `EditorPill`: one themed capsule
/// track holding a segment per case, the selected one filled with the theme accent. Replaces
/// `.pickerStyle(.segmented)`, which is AppKit-drawn and paints with the macOS system accent
/// no matter which Dosa theme is selected — the same reason `ThemedCalendarView` exists.
struct PillSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value

    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .pillCapsule()
        .fixedSize()
        .animation(.easeOut(duration: 0.12), value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note view")
    }

    private func segment(_ option: Value) -> some View {
        let isSelected = selection == option
        let isHovered = hovered == option
        return Button {
            selection = option
        } label: {
            Text(title(option))
                .appFont(size: 13)
                .foregroundStyle(isSelected ? Theme.current.onAccentColor : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background {
                    if isSelected {
                        Capsule().fill(Theme.current.accentColor)
                    } else if isHovered {
                        Capsule().fill(Theme.current.accentColor.opacity(0.10))
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hovered = hovering ? option : nil
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Closes an in-hierarchy popup when a click lands anywhere outside it. Needed because
/// `EditorPill`'s panels are overlays, not popovers, so nothing dismisses them for free.
/// Same mechanism as `SidebarDeselectCatcher`: a zero-size NSView installing a local
/// left-mouse-down monitor, walking the hit-test chain from the clicked view upward.
struct ClickOutsideCatcher: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onOutsideClick = onOutsideClick
    }

    final class MonitorView: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                    self?.handle(event)
                    return event
                }
            }
        }

        deinit {
            removeMonitor()
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window, let content = window.contentView else { return }
            var view = content.hitTest(event.locationInWindow)
            var inside = false
            while let current = view {
                if current is PanelMarkerView {
                    inside = true
                    break
                }
                // `.background(PanelMarker())` is a sibling of the SwiftUI content,
                // not an ancestor. Treat a marker sitting on this container as inside
                // so the pill and its overlay share one "inside" region.
                if current.subviews.contains(where: { $0 is PanelMarkerView }) {
                    inside = true
                    break
                }
                view = current.superview
            }
            if !inside {
                DispatchQueue.main.async { [weak self] in
                    self?.onOutsideClick?()
                }
            }
        }
    }
}

/// Marker the walk looks for. A click inside the panel hits a descendant of this view,
/// so the walk finds it and the panel stays open.
final class PanelMarkerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PanelMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> PanelMarkerView {
        PanelMarkerView()
    }

    func updateNSView(_ nsView: PanelMarkerView, context: Context) {}
}

/// App-drawn month grid so the selected-day fill and today ring follow
/// `Theme.current.accentColor`. `NSDatePicker` (under `DatePicker(.graphical)`)
/// paints its selection with `NSColor.controlAccentColor` and ignores `.tint`.
struct ThemedCalendarView: View {
    @Binding var selection: Date
    @State private var visibleMonth: Date

    private let calendar = Calendar.current
    private let cellSize: CGFloat = 30
    private let cellSpacing: CGFloat = 4

    init(selection: Binding<Date>) {
        self._selection = selection
        _visibleMonth = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            weekdayStrip
            dayGrid
        }
        .frame(width: gridWidth)
    }

    private var gridWidth: CGFloat {
        cellSize * 7 + cellSpacing * 6
    }

    private var header: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous month")

            Spacer()

            Text(monthTitle)
                .appFont(size: 13)

            Spacer()

            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next month")
        }
    }

    private var weekdayStrip: some View {
        HStack(spacing: cellSpacing) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .appFont(size: 11)
                    .foregroundStyle(Theme.secondaryTextColor)
                    .frame(width: cellSize)
            }
        }
    }

    private var dayGrid: some View {
        LazyVGrid(columns: columns, spacing: cellSpacing) {
            ForEach(0..<leadingBlankCount, id: \.self) { index in
                Color.clear
                    .frame(width: cellSize, height: cellSize)
                    .accessibilityHidden(true)
                    .id("blank-\(index)")
            }
            ForEach(daysInMonth, id: \.self) { day in
                dayCell(day)
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(day)
        return Button {
            select(day)
        } label: {
            Text(dayNumber(day))
                .appFont(size: 13)
                .foregroundStyle(isSelected ? Theme.current.onAccentColor : Color.primary)
                .frame(width: cellSize, height: cellSize)
                .background {
                    if isSelected {
                        Circle().fill(Theme.current.accentColor)
                    } else if isToday {
                        Circle().strokeBorder(Theme.current.accentColor)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: 7)
    }

    private var monthTitle: String {
        visibleMonth.formatted(.dateTime.month(.wide).year())
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }

    private var firstOfVisibleMonth: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth)) ?? visibleMonth
    }

    private var leadingBlankCount: Int {
        let weekday = calendar.component(.weekday, from: firstOfVisibleMonth)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private var daysInMonth: [Date] {
        let range = calendar.range(of: .day, in: .month, for: visibleMonth) ?? 1..<1
        return range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: firstOfVisibleMonth)
        }
    }

    private func dayNumber(_ day: Date) -> String {
        String(calendar.component(.day, from: day))
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: firstOfVisibleMonth) else { return }
        visibleMonth = next
    }

    /// Keep the existing time-of-day. `createdAt` orders the sidebar, and a
    /// naive midnight assignment would silently reshuffle the note list.
    private func select(_ day: Date) {
        let time = calendar.dateComponents([.hour, .minute, .second], from: selection)
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = time.hour
        parts.minute = time.minute
        parts.second = time.second
        if let combined = calendar.date(from: parts) { selection = combined }
    }
}

private extension View {
    /// Applies `transform` only when `condition` holds, for modifiers (like
    /// `.onHover`) that shouldn't be attached at all otherwise.
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, _ transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
