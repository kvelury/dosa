import SwiftUI
import AppKit

/// Screen-coordinate rects that floating surfaces (the recording bar, its
/// quick-settings panel, the toasts) have claimed as "not the text editor".
/// `PaddedTextView` subtracts these from the region it hands to
/// `addCursorRect(.iBeam)` in its own `resetCursorRects`, so the pointer reads
/// as an arrow over them instead of the I-beam an `NSTextView` would otherwise
/// claim across its whole visible rect.
///
/// Main-thread only, like the rest of the app's AppKit bridging code — no
/// actor isolation, matching `NSCursor`'s own threading model.
///
/// Any new floating overlay drawn over the editor must apply
/// `.textCursorCarveOut()` or it will silently regress into the same bug
/// documented in `docs/TECHNICAL_DESIGN.md`.
final class TextCursorCarveOutRegistry {
    static let shared = TextCursorCarveOutRegistry()

    private var rects: [ObjectIdentifier: NSRect] = [:]
    private var textViews = NSHashTable<NSTextView>.weakObjects()

    private init() {}

    func register(_ id: ObjectIdentifier, screenRect: NSRect) {
        rects[id] = screenRect
        invalidateAll()
    }

    func unregister(_ id: ObjectIdentifier) {
        guard rects.removeValue(forKey: id) != nil else { return }
        invalidateAll()
    }

    func registerTextView(_ textView: NSTextView) {
        textViews.add(textView)
    }

    /// Registered carve-out rects converted into `window`'s coordinate space.
    func carveOuts(in window: NSWindow) -> [NSRect] {
        rects.values.map { window.convertFromScreen($0) }
    }

    /// Whether `screenPoint` falls inside any registered carve-out.
    func contains(screenPoint: NSPoint) -> Bool {
        rects.values.contains { $0.contains(screenPoint) }
    }

    private func invalidateAll() {
        for textView in textViews.allObjects where textView.window != nil {
            textView.window?.invalidateCursorRects(for: textView)
        }
    }
}

/// Marks a view's frame as a cursor carve-out — see `TextCursorCarveOutRegistry`.
extension View {
    func textCursorCarveOut() -> some View {
        background(CarveOutMarker())
    }
}

private struct CarveOutMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ nsView: MarkerView, context: Context) {}

    static func dismantleNSView(_ nsView: MarkerView, coordinator: ()) {
        TextCursorCarveOutRegistry.shared.unregister(ObjectIdentifier(nsView))
    }

    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            reportFrame()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportFrame()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                TextCursorCarveOutRegistry.shared.unregister(ObjectIdentifier(self))
            }
        }

        private func reportFrame() {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            let screenRect = window.convertToScreen(convert(bounds, to: nil))
            TextCursorCarveOutRegistry.shared.register(ObjectIdentifier(self), screenRect: screenRect)
        }

        override func resetCursorRects() {
            // The surface defaults to arrow; controls inside it that want the
            // pointing hand add their own rect via `.cursor(_:)`, which wins on
            // overlap because it resets after this ancestor in the same pass.
            addCursorRect(bounds, cursor: .arrow)
        }
    }
}

/// A robust per-control cursor via an AppKit cursor rect — not `.onHover` +
/// `NSCursor.push()/pop()`, which leaves the cursor stack unbalanced if a hover
/// event is ever dropped. Only takes effect where something else (the window's
/// default, or a `.textCursorCarveOut()` ancestor) isn't already claiming the
/// I-beam over the text editor underneath.
extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        overlay(CursorRectOverlay(cursor: cursor))
    }
}

private struct CursorRectOverlay: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorRectNSView {
        let view = CursorRectNSView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorRectNSView, context: Context) {
        nsView.cursor = cursor
    }

    final class CursorRectNSView: NSView {
        var cursor: NSCursor = .arrow {
            didSet { window?.invalidateCursorRects(for: self) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }
    }
}
