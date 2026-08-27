import SwiftUI
import AppKit

/// A lightweight markdown editor: plain markdown text stays fully editable while
/// headings, bullets, numbered lists, quotes, bold/italic, and code render live
/// with real formatting (sizes, colors, hanging indents). Return auto-continues
/// list items; Return on an empty item ends the list.
struct TextHighlight: Equatable {
    let id: UUID
    let range: NSRange
}

/// NSTextView with independent top and bottom padding. `textContainerInset` is
/// symmetric, so we set it to the average and pin the container at `topPadding`
/// — the remainder becomes bottom padding that content can scroll into (clearing
/// the floating bar) without any NSScrollView contentInsets tiling quirks.
final class PaddedTextView: NSTextView {
    var topPadding: CGFloat = 12

    /// An audio/video file was dropped on the text. NSTextView would otherwise accept
    /// the drag itself and paste the file's path as text, so media drops are
    /// intercepted here — this view sits above the editor and wins the drag.
    var onMediaFileDrop: ((URL) -> Void)?
    /// Whether an importable file is currently hovering, so the editor can show the
    /// same drop highlight it shows for drags outside the text area.
    var onMediaDragChanged: ((Bool) -> Void)?

    private var clipObserver: NSObjectProtocol?

    private func importableURL(from info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        return urls?.first(where: RecordingImporter.canImport)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard importableURL(from: sender) != nil else { return super.draggingEntered(sender) }
        onMediaDragChanged?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard importableURL(from: sender) != nil else { return super.draggingUpdated(sender) }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onMediaDragChanged?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onMediaDragChanged?(false)
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        importableURL(from: sender) != nil ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = importableURL(from: sender) else { return super.performDragOperation(sender) }
        onMediaDragChanged?(false)
        onMediaFileDrop?(url)
        return true
    }

    private var activeUndoManager: UndoManager? {
        (delegate as? NSTextViewDelegate)?.undoManager?(for: self) ?? undoManager
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if isEditable, event.charactersIgnoringModifiers?.lowercased() == "z" {
            if flags == .command {
                activeUndoManager?.undo()
                return true
            }
            if flags == [.command, .shift] {
                activeUndoManager?.redo()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: super.textContainerOrigin.x, y: topPadding)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let observer = clipObserver {
            NotificationCenter.default.removeObserver(observer)
            clipObserver = nil
        }
        guard let clipView = superview as? NSClipView else { return }
        clipView.postsFrameChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            self?.syncWithClipView()
        }
        syncWithClipView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            TextCursorCarveOutRegistry.shared.registerTextView(self)
        }
    }

    // MARK: - Cursor

    /// Claims the I-beam everywhere in `visibleRect` except the rects that
    /// floating surfaces (the recording bar, its quick-settings panel, the
    /// toasts) have registered via `.textCursorCarveOut()`. An `NSTextView`
    /// re-asserts its cursor rects from here on every layout pass, which is why
    /// nothing drawn merely *above* it in the view hierarchy can win the
    /// pointer — subtracting the claim is the only fix that sticks.
    ///
    /// The carve-out is each surface's bounding rect, not its exact silhouette
    /// (e.g. the pedestal's concave corners beside the pull-tab) — a sliver of
    /// text can show arrow instead of I-beam there. Clicks still reach the text
    /// view; only the pointer glyph is imprecise, and that's an accepted trade
    /// for not tracking per-shape geometry.
    override func resetCursorRects() {
        guard let window else {
            super.resetCursorRects()
            return
        }
        let holes = TextCursorCarveOutRegistry.shared.carveOuts(in: window)
            .map { convert($0, from: nil) }
            .filter { $0.intersects(visibleRect) }
        guard !holes.isEmpty else {
            addCursorRect(visibleRect, cursor: .iBeam)
            return
        }
        for rect in Self.subtracting(holes, from: visibleRect) {
            addCursorRect(rect, cursor: .iBeam)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard shouldYieldCursor() else {
            super.mouseMoved(with: event)
            return
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard shouldYieldCursor() else {
            super.cursorUpdate(with: event)
            return
        }
    }

    /// True when the text view must not touch the cursor at all: the pointer is
    /// over a registered carve-out, or this window isn't actually the frontmost
    /// thing under the pointer — a popover (the calendar, note search) is a
    /// separate child window, and this view's cursor rects and mouse-moved
    /// tracking keep firing underneath it unless told otherwise.
    private func shouldYieldCursor() -> Bool {
        guard let window else { return false }
        let screenPoint = NSEvent.mouseLocation
        if TextCursorCarveOutRegistry.shared.contains(screenPoint: screenPoint) {
            return true
        }
        let topWindowNumber = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        return topWindowNumber != window.windowNumber
    }

    /// Subtracts each rect in `holes` from `rect`, splitting into the
    /// surviving axis-aligned pieces. A handful of small holes is the only
    /// case this needs to handle well.
    private static func subtracting(_ holes: [NSRect], from rect: NSRect) -> [NSRect] {
        var pieces = [rect]
        for hole in holes {
            pieces = pieces.flatMap { subtracting(hole, from: $0) }
        }
        return pieces.filter { $0.width > 0 && $0.height > 0 }
    }

    private static func subtracting(_ hole: NSRect, from piece: NSRect) -> [NSRect] {
        guard hole.intersects(piece) else { return [piece] }
        let overlap = hole.intersection(piece)
        var result: [NSRect] = []
        if overlap.minY > piece.minY {
            result.append(NSRect(x: piece.minX, y: piece.minY, width: piece.width, height: overlap.minY - piece.minY))
        }
        if overlap.maxY < piece.maxY {
            result.append(NSRect(x: piece.minX, y: overlap.maxY, width: piece.width, height: piece.maxY - overlap.maxY))
        }
        if overlap.minX > piece.minX {
            result.append(NSRect(x: piece.minX, y: overlap.minY, width: overlap.minX - piece.minX, height: overlap.height))
        }
        if overlap.maxX < piece.maxX {
            result.append(NSRect(x: overlap.maxX, y: overlap.minY, width: piece.maxX - overlap.maxX, height: overlap.height))
        }
        return result
    }

    deinit {
        if let observer = clipObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Keep the view exactly as wide as the viewport (so text re-wraps on window
    /// resize) and at least as tall (so clicks below short content still focus
    /// the editor) — scrollableTextView() gave us both for free.
    private func syncWithClipView() {
        guard let clipView = superview as? NSClipView else { return }
        minSize = NSSize(width: 0, height: clipView.bounds.height)
        let targetWidth = clipView.bounds.width
        if frame.width != targetWidth || frame.height < minSize.height {
            setFrameSize(NSSize(width: targetWidth, height: max(frame.height, minSize.height)))
            if let container = textContainer {
                layoutManager?.ensureLayout(for: container)
            }
            sizeToFit()
            if frame.height < minSize.height {
                setFrameSize(NSSize(width: targetWidth, height: minSize.height))
            }
        }
    }
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Observed so a font change restyles the NSTextView without waiting for
    /// Settings to close (the fingerprint comparison below does the restyle).
    @AppStorage(AppSettings.fontFamilyKey) private var fontFamily = AppFontChoice.system.rawValue
    /// When set, tokens NOT present in this base text (i.e. Dosa's additions) are
    /// tinted with the diff color, while surviving user tokens stay primary.
    var diffAgainst: String?
    var isEditable = true
    /// A one-shot scroll-to-and-flash request (from search).
    var highlight: TextHighlight?
    /// Extra scrollable space at the bottom so content can clear overlaid chrome
    /// (like the floating action bar).
    var bottomContentInset: CGFloat = 0
    /// Handles an audio/video file dropped on the text, which the text view would
    /// otherwise paste as a file path.
    var onMediaFileDrop: ((URL) -> Void)?
    var onMediaDragChanged: ((Bool) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PaddedTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

        let bottomPadding = bottomContentInset > 0 ? bottomContentInset : 12
        textView.topPadding = 12
        textView.textContainerInset = NSSize(width: 16, height: (12 + bottomPadding) / 2)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        textView.isEditable = isEditable
        textView.string = text
        textView.onMediaFileDrop = onMediaFileDrop
        textView.onMediaDragChanged = onMediaDragChanged
        MarkdownStyler.style(textView, diffBase: diffAgainst)
        applyHighlight(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if let padded = textView as? PaddedTextView {
            // Re-bound each update: the closures capture view state that changes.
            padded.onMediaFileDrop = onMediaFileDrop
            padded.onMediaDragChanged = onMediaDragChanged
        }
        let fingerprint = "\(Theme.styleFingerprint)|\(fontFamily)"
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            MarkdownStyler.style(textView, diffBase: diffAgainst)
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        } else if context.coordinator.lastStyleFingerprint != fingerprint {
            MarkdownStyler.style(textView, diffBase: diffAgainst)
        }
        context.coordinator.lastStyleFingerprint = fingerprint
        applyHighlight(to: textView, coordinator: context.coordinator)
    }

    private func applyHighlight(to textView: NSTextView, coordinator: Coordinator) {
        guard let highlight, coordinator.lastHighlightId != highlight.id else { return }
        coordinator.lastHighlightId = highlight.id
        let length = (textView.string as NSString).length
        let range = highlight.range
        guard range.length > 0, range.location >= 0, range.location + range.length <= length else { return }
        Self.flashWhenVisible(textView, range: range, attempts: 20)
    }

    /// The find indicator only renders once the view is in a window that has
    /// finished presenting (e.g. the transcript sheet's open animation). Poll
    /// briefly until then, then scroll and flash.
    private static func flashWhenVisible(_ textView: NSTextView, range: NSRange, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak textView] in
            guard let textView else { return }
            guard range.location + range.length <= (textView.string as NSString).length else { return }
            guard let window = textView.window, window.isVisible, window.occlusionState.contains(.visible) else {
                if attempts > 0 {
                    flashWhenVisible(textView, range: range, attempts: attempts - 1)
                }
                return
            }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            textView.scrollRangeToVisible(range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak textView] in
                textView?.showFindIndicator(for: range)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        var lastHighlightId: UUID?
        var lastStyleFingerprint = Theme.styleFingerprint
        private let editorUndoManager = UndoManager()

        private static let listPrefix = try! NSRegularExpression(
            pattern: #"^(\s*)([-*+]|\d+\.)(\s+)(.*)$"#
        )
        private static let indentUnit = "    "

        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            editorUndoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            MarkdownStyler.style(textView, diffBase: parent.diffAgainst)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return continueList(in: textView)
            case #selector(NSResponder.insertTab(_:)):
                return indent(textView, outdent: false)
            case #selector(NSResponder.insertBacktab(_:)):
                return indent(textView, outdent: true)
            default:
                return false
            }
        }

        /// Tab indents the current line(s) by four spaces — for list items the
        /// marker moves with the line, so bullets step to the next column.
        /// Shift+Tab outdents. A plain cursor on a non-list line just gets spaces.
        private func indent(_ textView: NSTextView, outdent: Bool) -> Bool {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            let firstLine = ns.substring(with: ns.lineRange(for: NSRange(location: selection.location, length: 0)))
            let firstLineNS = firstLine as NSString
            let isList = Self.listPrefix.firstMatch(
                in: firstLine, range: NSRange(location: 0, length: firstLineNS.length)
            ) != nil

            if !outdent, selection.length == 0, !isList {
                textView.insertText(Self.indentUnit, replacementRange: selection)
                return true
            }

            let lineRange = ns.lineRange(for: selection)
            let block = ns.substring(with: lineRange)
            let hadTrailingNewline = block.hasSuffix("\n")
            var lines = block.components(separatedBy: "\n")
            if hadTrailingNewline {
                lines.removeLast()
            }

            var firstLineDelta = 0
            for (index, line) in lines.enumerated() {
                if outdent {
                    var trimmed = line
                    var removed = 0
                    while removed < Self.indentUnit.count, trimmed.hasPrefix(" ") {
                        trimmed.removeFirst()
                        removed += 1
                    }
                    if removed == 0, trimmed.hasPrefix("\t") {
                        trimmed.removeFirst()
                        removed = 1
                    }
                    lines[index] = trimmed
                    if index == 0 { firstLineDelta = -removed }
                } else if !line.isEmpty {
                    lines[index] = Self.indentUnit + line
                    if index == 0 { firstLineDelta = Self.indentUnit.count }
                }
            }

            var replacement = lines.joined(separator: "\n")
            if hadTrailingNewline {
                replacement += "\n"
            }
            guard replacement != block else { return true }
            guard textView.shouldChangeText(in: lineRange, replacementString: replacement) else { return true }
            textView.replaceCharacters(in: lineRange, with: replacement)
            textView.didChangeText()

            if selection.length == 0 {
                let newLocation = max(lineRange.location, selection.location + firstLineDelta)
                textView.setSelectedRange(NSRange(location: min(newLocation, (textView.string as NSString).length), length: 0))
            } else {
                textView.setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
            }
            return true
        }

        private func continueList(in textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.length == 0, selection.location <= ns.length else { return false }

            let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            var line = ns.substring(with: lineRange)
            if line.hasSuffix("\n") { line.removeLast() }
            let lineNS = line as NSString

            guard let match = Self.listPrefix.firstMatch(
                in: line, range: NSRange(location: 0, length: lineNS.length)
            ) else { return false }

            let indent = lineNS.substring(with: match.range(at: 1))
            let marker = lineNS.substring(with: match.range(at: 2))
            let content = lineNS.substring(with: match.range(at: 4))

            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                // Return on an empty list item ends the list: clear the marker.
                let prefixLength = match.range(at: 4).location
                let markerRange = NSRange(location: lineRange.location, length: prefixLength)
                if textView.shouldChangeText(in: markerRange, replacementString: "") {
                    textView.replaceCharacters(in: markerRange, with: "")
                    textView.didChangeText()
                }
                return true
            }

            var nextMarker = marker
            if marker.hasSuffix("."), let number = Int(marker.dropLast()) {
                nextMarker = "\(number + 1)."
            }
            textView.insertText("\n\(indent)\(nextMarker) ", replacementRange: selection)
            return true
        }
    }
}

enum MarkdownStyler {
    /// Unscaled; every actual size read from this type goes through
    /// `Typography.scaled(_:)` so the editor tracks the Text Size setting.
    static let baseFontSize: CGFloat = 14
    static var baseFont: NSFont { Typography.nsFont(size: Typography.scaled(baseFontSize)) }
    static var monoFont: NSFont { Typography.nsMono(size: Typography.scaled(baseFontSize - 1)) }
    static var markerColor: NSColor { Theme.tertiaryText }
    static var bulletColor: NSColor { Theme.current.highlight }
    static var codeSpanColor: NSColor { Theme.current.codeSpan }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 2
        return [
            .font: baseFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: paragraph,
        ]
    }

    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})(\s+)"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^(\s*)([-*+])(\s+)"#)
    private static let numbered = try! NSRegularExpression(pattern: #"^(\s*)(\d+\.)(\s+)"#)
    private static let quote = try! NSRegularExpression(pattern: #"^(\s*)(>)(\s?)"#)
    private static let fence = try! NSRegularExpression(pattern: #"^\s*```"#)
    private static let codeSpan = try! NSRegularExpression(pattern: #"(`)([^`\n]+)(`)"#)
    private static let bold = try! NSRegularExpression(pattern: #"(\*\*)([^\*\n]+?)(\*\*)"#)
    private static let italic = try! NSRegularExpression(
        pattern: #"(?<![\*\w])(\*)([^\*\n]+?)(\*)(?!\*)|(?<![\w_])(_)([^_\n]+?)(_)(?![\w])"#
    )

    static func headingFont(level: Int) -> NSFont {
        let size: CGFloat
        switch level {
        case 1: size = 23
        case 2: size = 19
        case 3: size = 16
        default: size = 14.5
        }
        return Typography.nsFont(size: Typography.scaled(size), weight: .bold)
    }

    static func style(_ textView: NSTextView, diffBase: String? = nil) {
        guard let storage = textView.textStorage else { return }
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)

        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        var inCodeBlock = false
        ns.enumerateSubstrings(in: full, options: [.byLines]) { substring, lineRange, _, _ in
            guard let line = substring else { return }
            let localRange = NSRange(location: 0, length: (line as NSString).length)

            if fence.firstMatch(in: line, range: localRange) != nil {
                storage.addAttribute(.font, value: monoFont, range: lineRange)
                storage.addAttribute(.foregroundColor, value: markerColor, range: lineRange)
                inCodeBlock.toggle()
                return
            }
            if inCodeBlock {
                storage.addAttribute(.font, value: monoFont, range: lineRange)
                storage.addAttribute(.foregroundColor, value: Theme.secondaryText, range: lineRange)
                return
            }
            styleLine(line, lineRange: lineRange, storage: storage)
        }
        if let diffBase {
            applyDiffColors(base: diffBase, storage: storage)
        }
        storage.endEditing()

        var typingAttributes = baseAttributes
        if diffBase != nil {
            // Anything newly typed is by definition not in the manual notes,
            // so it starts out in the addition color (see applyDiffColors).
            typingAttributes[.foregroundColor] = DiffEngine.aiNSColor
        }
        textView.typingAttributes = typingAttributes
    }

    /// Tints every token that does not survive from `base` (the manual notes)
    /// with the Dosa-addition color. Runs after markdown styling so fonts
    /// and indents are preserved.
    private static func applyDiffColors(base: String, storage: NSTextStorage) {
        let (tokens, ranges) = tokenizeWithRanges(storage.string)
        let baseTokens = DiffEngine.tokenize(base)
        var insertedOffsets = Set<Int>()
        for case let .insert(offset, _, _) in tokens.difference(from: baseTokens).insertions {
            insertedOffsets.insert(offset)
        }
        for (offset, range) in ranges.enumerated() where insertedOffsets.contains(offset) && range.length > 0 {
            storage.addAttribute(.foregroundColor, value: DiffEngine.aiNSColor, range: range)
        }
    }

    /// Same tokenization as DiffEngine.tokenize, but also returns each token's NSRange.
    private static func tokenizeWithRanges(_ text: String) -> ([String], [NSRange]) {
        var tokens: [String] = []
        var ranges: [NSRange] = []
        var currentStart: String.Index?
        var index = text.startIndex

        func flush(_ end: String.Index) {
            guard let start = currentStart else { return }
            tokens.append(String(text[start..<end]))
            ranges.append(NSRange(start..<end, in: text))
            currentStart = nil
        }

        while index < text.endIndex {
            let character = text[index]
            if character == "\n" {
                flush(index)
                tokens.append("\n")
                ranges.append(NSRange(index..<text.index(after: index), in: text))
            } else if character == " " || character == "\t" {
                flush(index)
            } else if currentStart == nil {
                currentStart = index
            }
            index = text.index(after: index)
        }
        flush(text.endIndex)
        return (tokens, ranges)
    }

    private static func styleLine(_ line: String, lineRange: NSRange, storage: NSTextStorage) {
        let lineNS = line as NSString
        let localRange = NSRange(location: 0, length: lineNS.length)

        func global(_ range: NSRange) -> NSRange {
            NSRange(location: lineRange.location + range.location, length: range.length)
        }

        // Inline styling must skip the list/quote marker prefix, otherwise a "*"
        // bullet pairs with a stray "*" later in the line and fakes an italic run.
        var inlineStart = 0

        if let match = heading.firstMatch(in: line, range: localRange) {
            let level = match.range(at: 1).length
            storage.addAttribute(.font, value: headingFont(level: level), range: lineRange)
            storage.addAttribute(.foregroundColor, value: markerColor, range: global(match.range(at: 1)))
            inlineStart = match.range.location + match.range.length
        } else if let match = bullet.firstMatch(in: line, range: localRange)
                    ?? numbered.firstMatch(in: line, range: localRange) {
            storage.addAttribute(.foregroundColor, value: bulletColor, range: global(match.range(at: 2)))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 2
            let prefixWidth = CGFloat(match.range(at: 3).location + match.range(at: 3).length)
            paragraph.headIndent = prefixWidth * (Typography.scaled(baseFontSize) * 0.52)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
            inlineStart = match.range.location + match.range.length
        } else if let match = quote.firstMatch(in: line, range: localRange) {
            storage.addAttribute(.foregroundColor, value: Theme.secondaryText, range: lineRange)
            storage.addAttribute(.foregroundColor, value: bulletColor, range: global(match.range(at: 2)))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.headIndent = Typography.scaled(baseFontSize)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
            inlineStart = match.range.location + match.range.length
        }

        let inlineRange = NSRange(location: inlineStart, length: lineNS.length - inlineStart)

        for match in codeSpan.matches(in: line, range: inlineRange) {
            storage.addAttribute(.font, value: monoFont, range: global(match.range))
            storage.addAttribute(.foregroundColor, value: codeSpanColor, range: global(match.range(at: 2)))
            storage.addAttribute(.foregroundColor, value: markerColor, range: global(match.range(at: 1)))
            storage.addAttribute(.foregroundColor, value: markerColor, range: global(match.range(at: 3)))
        }
        for match in bold.matches(in: line, range: inlineRange) {
            applyTrait(.boldFontMask, range: global(match.range(at: 2)), storage: storage)
            storage.addAttribute(.foregroundColor, value: markerColor, range: global(match.range(at: 1)))
            storage.addAttribute(.foregroundColor, value: markerColor, range: global(match.range(at: 3)))
        }
        for match in italic.matches(in: line, range: inlineRange) {
            let contentGroup = match.range(at: 2).location != NSNotFound ? 2 : 5
            applyTrait(.italicFontMask, range: global(match.range(at: contentGroup)), storage: storage)
            for markerGroup in [contentGroup - 1, contentGroup + 1] {
                storage.addAttribute(.foregroundColor, value: markerColor, range: global(match.range(at: markerGroup)))
            }
        }
    }

    private static func applyTrait(_ trait: NSFontTraitMask, range: NSRange, storage: NSTextStorage) {
        guard range.length > 0 else { return }
        storage.enumerateAttribute(.font, in: range) { value, subRange, _ in
            let font = (value as? NSFont) ?? baseFont
            let converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: converted, range: subRange)
        }
    }
}
