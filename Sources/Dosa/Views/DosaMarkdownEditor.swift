import SwiftUI
import AppKit
import MarkdownEngine

/// A one-shot scroll-to-and-flash request (from search).
struct TextHighlight: Equatable {
    let id: UUID
    let range: NSRange
}

/// The note editor. Text in and out is plain Markdown — persistence, search,
/// the AI diff, Notion export and the file exports all read that string, so the
/// storage form never diverges from what the user typed.
///
/// The live styling, list handling, undo, spell-check and find come from
/// `MarkdownEngine` (a TextKit 2 `NSTextView`); what stays here is everything
/// the engine can't know about: the Dosa-additions tint, audio/video drops, the
/// floating bar's cursor carve-outs, and the app's typography.
struct DosaMarkdownEditor: View {
    @Binding var text: String
    /// When set, tokens NOT present in this base text (i.e. Dosa's additions) are
    /// tinted with the diff color, while surviving user tokens stay primary.
    var diffAgainst: String?
    var isEditable = true
    /// A one-shot scroll-to-and-flash request (from search).
    var highlight: TextHighlight?
    /// Extra scrollable space at the bottom so content can clear overlaid chrome
    /// (like the floating action bar).
    var bottomContentInset: CGFloat = 0
    /// Identifies the document so undo history and scroll offset stay with it.
    var documentId: String = "default"
    /// Handles an audio/video file dropped on the text, which the text view would
    /// otherwise paste as a file path.
    var onMediaFileDrop: ((URL) -> Void)?
    var onMediaDragChanged: ((Bool) -> Void)?

    /// Observed so a font or theme change restyles without waiting for Settings
    /// to close — the engine re-reads `fontName`/`fontSize` on every update.
    @AppStorage(AppSettings.fontFamilyKey) private var fontFamily = AppFontChoice.system.rawValue
    @AppStorage(AppSettings.textSizeKey) private var textSize = AppTextSize.regular.rawValue
    @AppStorage(AppSettings.themeKey) private var themeName = "Classic"
    @AppStorage(AppSettings.dosaColorKey) private var dosaColorName = "Theme Default"

    /// Resolves the engine's `NSTextView` so search can scroll to and flash a
    /// range. The engine owns the view and exposes no handle, so a marker view
    /// planted in the same SwiftUI layout finds it in the AppKit tree.
    @StateObject private var handle = MarkdownEditorHandle()

    /// Base editor point size before the Text Size multiplier.
    static let baseFontSize: CGFloat = 14

    private var resolvedFontSize: CGFloat { Typography.scaled(Self.baseFontSize) }

    var body: some View {
        NativeTextViewWrapper(
            text: $text,
            configuration: configuration,
            fontName: Typography.nsFont(size: resolvedFontSize).fontName,
            fontSize: resolvedFontSize,
            documentId: documentId,
            isEditable: isEditable,
            isCursorExcluded: { pointInWindow in
                // The engine asks in window coordinates; the registry stores screen rects.
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
                let screenPoint = window.convertPoint(toScreen: pointInWindow)
                return TextCursorCarveOutRegistry.shared.contains(screenPoint: screenPoint)
            },
            decorate: diffDecorator,
            canAcceptDrop: { Self.importableURL(from: $0) != nil },
            onFileDrop: { info in
                guard let url = Self.importableURL(from: info) else { return false }
                onMediaFileDrop?(url)
                return true
            },
            onDragHoverChange: { onMediaDragChanged?($0) }
        )
        .background(MarkdownEditorLocator(handle: handle))
        .onChange(of: highlight) { _, newValue in
            guard let newValue else { return }
            handle.flash(newValue.range)
        }
        .onAppear {
            guard let highlight else { return }
            handle.flash(highlight.range)
        }
    }

    // MARK: - Engine configuration

    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default
        config.theme = Self.theme
        // Full width: the note pane is already narrow, and the live split can
        // take it to 320pt, where a centered reading column would waste half of it.
        config.readingWidth = nil
        config.heightBehavior = .scrolls
        config.textInsets = TextInsets(horizontal: 16, vertical: 12)
        // Clears the floating bar. `minPoints` matches so a short note can still
        // scroll its last line out from under the bar.
        config.safeAreaInsets = SafeAreaInsets(bottom: bottomContentInset)
        config.overscroll = OverscrollPolicy(minPoints: max(40, bottomContentInset))
        config.lists.helpersEnabled = true
        // `[` and `(` autoclose fights markdown link typing more than it helps.
        config.lists.autoClosePairsEnabled = false
        return config
    }

    private static var theme: MarkdownEditorTheme {
        MarkdownEditorTheme(
            bodyText: .textColor,
            mutedText: Theme.secondaryText,
            disabledText: Theme.tertiaryText,
            headingMarker: Theme.tertiaryText,
            link: Theme.current.accent,
            incompleteLink: Theme.tertiaryText,
            findMatchHighlight: Theme.current.highlight,
            findCurrentMatchHighlight: Theme.current.highlightDeep,
            strikethroughColor: Theme.secondaryText,
            highlightColor: Theme.current.highlight.withAlphaComponent(0.4)
        )
    }

    // MARK: - Dosa-additions tint

    /// Re-applies the AI-addition color over whatever the engine just restyled.
    /// Nil outside Dosa Notes so the engine's own styling stands unaltered.
    private var diffDecorator: ((NSMutableAttributedString, NSRange) -> Void)? {
        guard let diffAgainst else { return nil }
        let color = DiffEngine.aiNSColor
        return { storage, range in
            DiffTint.apply(base: diffAgainst, color: color, to: storage, in: range)
        }
    }

    private static func importableURL(from info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return urls?.first(where: RecordingImporter.canImport)
    }
}

// MARK: - Text view handle

/// Holds the engine's `NSTextView` so search can scroll to and flash a range.
final class MarkdownEditorHandle: ObservableObject {
    weak var textView: NSTextView?

    func flash(_ range: NSRange) {
        guard let textView else { return }
        Self.flashWhenVisible(textView, range: range, attempts: 20)
    }

    /// The find indicator only renders once the view is in a window that has
    /// finished presenting (e.g. the transcript sheet's open animation). Poll
    /// briefly until then, then scroll and flash.
    private static func flashWhenVisible(_ textView: NSTextView, range: NSRange, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak textView] in
            guard let textView else { return }
            guard range.length > 0, range.location >= 0,
                  NSMaxRange(range) <= (textView.string as NSString).length else { return }
            guard let window = textView.window, window.isVisible,
                  window.occlusionState.contains(.visible) else {
                if attempts > 0 {
                    flashWhenVisible(textView, range: range, attempts: attempts - 1)
                }
                return
            }
            textView.textLayoutManager.map { $0.ensureLayout(for: $0.documentRange) }
            textView.scrollRangeToVisible(range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak textView] in
                textView?.showFindIndicator(for: range)
            }
        }
    }
}

/// Plants a zero-size marker behind the editor and walks the AppKit tree from it
/// to the engine's text view. Searching from the marker's own ancestors rather
/// than the window keeps it on *this* editor when more than one is on screen.
private struct MarkdownEditorLocator: NSViewRepresentable {
    let handle: MarkdownEditorHandle

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.handle = handle
        return view
    }

    func updateNSView(_ nsView: MarkerView, context: Context) {
        nsView.handle = handle
        nsView.locate()
    }

    final class MarkerView: NSView {
        var handle: MarkdownEditorHandle?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            locate()
        }

        /// Climbs to the nearest ancestor that contains a text view and claims it.
        func locate() {
            guard handle?.textView == nil, window != nil else { return }
            var ancestor: NSView? = superview
            while let view = ancestor {
                if let found = Self.firstTextView(in: view) {
                    handle?.textView = found
                    TextCursorCarveOutRegistry.shared.registerTextView(found)
                    return
                }
                ancestor = view.superview
            }
        }

        private static func firstTextView(in view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView { return textView }
            for subview in view.subviews {
                if let found = firstTextView(in: subview) { return found }
            }
            return nil
        }
    }
}
