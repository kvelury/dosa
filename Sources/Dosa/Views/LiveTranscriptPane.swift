import SwiftUI

/// The right-hand pane of the editor while a live-mode recording runs: a running
/// transcript that sticks to the newest line until the user scrolls back, then
/// holds their place and offers a "Jump to latest" pill instead of yanking the
/// view down on every new word.
struct LiveTranscriptPane: View {
    @ObservedObject var live: LiveTranscriber

    /// True while the view should follow new lines. Cleared when the user scrolls
    /// away from the bottom, restored by the jump pill (or scrolling back down).
    @State private var pinnedToBottom = true
    @State private var viewportHeight: CGFloat = 0

    private static let bottomAnchorID = "live-transcript-bottom"
    /// How far (pt) above the bottom the user can drift before auto-follow stops.
    private static let unpinSlack: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
        .background(Theme.current.editorBackgroundColor)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Live Transcript", systemImage: "text.bubble")
                .appFont(.headline)
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Spacer()
            Text("On-device")
                .appFont(.caption)
                .foregroundStyle(Theme.tertiaryTextColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live transcript, recording")
    }

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if live.lines.isEmpty {
                            Text("Listening…")
                                .appFont(.body)
                                .foregroundStyle(Theme.secondaryTextColor)
                                .padding(.top, 12)
                        }
                        ForEach(live.lines) { line in
                            row(line)
                        }
                        // Scroll target + pin sensor: when this sits within the
                        // viewport (plus slack), the user is at the bottom.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomAnchorID)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: LiveTranscriptBottomKey.self,
                                        value: geo.frame(in: .named("liveTranscriptScroll")).minY
                                    )
                                }
                            )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .coordinateSpace(name: "liveTranscriptScroll")
                .onPreferenceChange(LiveTranscriptBottomKey.self) { bottomY in
                    pinnedToBottom = bottomY <= viewportHeight + Self.unpinSlack
                }
                .onChange(of: live.lines) { _, _ in
                    guard pinnedToBottom else { return }
                    // Unanimated on purpose: volatile updates arrive several
                    // times a second and animating each scroll burns CPU.
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onAppear {
                    viewportHeight = viewport.size.height
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: viewport.size.height) { _, height in
                    viewportHeight = height
                }
                .overlay(alignment: .bottom) {
                    if !pinnedToBottom {
                        Button {
                            pinnedToBottom = true
                            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                                .appFont(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Theme.current.accentColor))
                                .foregroundStyle(Theme.current.onAccentColor)
                        }
                        .buttonStyle(.plain)
                        .cursor(.pointingHand)
                        .padding(.bottom, 10)
                        .accessibilityLabel("Jump to the latest transcript line")
                    }
                }
            }
        }
    }

    private func row(_ line: LiveTranscriber.LiveLine) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(line.speaker)
                    .appFont(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.current.accentColor)
                Text("[\(AppleTranscriber.mmss(line.start))]")
                    .appFont(.caption, monospacedDigit: true)
                    .foregroundStyle(Theme.tertiaryTextColor)
            }
            Text(line.text)
                .appFont(.body)
                .foregroundStyle(.primary)
                .opacity(line.isFinal ? 1 : 0.55)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.speaker), \(line.text)\(line.isFinal ? "" : ", still transcribing")")
    }
}

private struct LiveTranscriptBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}
