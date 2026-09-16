import SwiftUI
import AppKit

/// Click-outside-to-close for SwiftUI presentations that don't do it themselves.
///
/// Popovers already dismiss on an outside click; sheets never do. Both modifiers
/// here work the same way — an `NSEvent` local monitor, which sees mouse-downs as
/// `NSApp` dispatches them, including clicks on a window that a sheet has blocked
/// (those never reach the window itself, so there is nothing else to hook).

/// Reports the AppKit view backing a SwiftUI view once it is actually in a window.
/// `makeNSView` is too early — the view has no window yet.
private struct HostViewReader: NSViewRepresentable {
    let onAttach: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        ReaderView(onAttach: onAttach)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        private let onAttach: (NSView) -> Void

        init(onAttach: @escaping (NSView) -> Void) {
            self.onAttach = onAttach
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("HostViewReader.ReaderView is never loaded from a nib")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            onAttach(self)
        }
    }
}

/// Holds what the event monitor needs to read *at click time*. A plain `@State`
/// value would be captured by the monitor's closure at install time — when the
/// window is still unknown — so the live reference goes through this box.
private final class OutsideClickContext {
    var view: NSView?
    var monitor: Any?

    func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

private struct DismissOnOutsideClick: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var context = OutsideClickContext()

    func body(content: Content) -> some View {
        content
            .background(
                HostViewReader { view in
                    context.view = view
                    install()
                }
                .allowsHitTesting(false)
            )
            .onDisappear { context.removeMonitor() }
    }

    private func install() {
        context.removeMonitor()
        let context = self.context
        context.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let sheetWindow = context.view?.window,
                  let parent = sheetWindow.sheetParent,
                  event.window === parent,
                  // A sheet of our own is up (e.g. the Google client paste sheet
                  // over Settings). Dismissing now would take the child — and
                  // whatever was typed into it — with us.
                  sheetWindow.attachedSheet == nil
            else { return event }
            dismiss()
            return event
        }
    }
}

private struct OutsideClickCatcher: ViewModifier {
    let action: () -> Void
    @State private var context = OutsideClickContext()

    func body(content: Content) -> some View {
        content
            .background(
                HostViewReader { view in
                    context.view = view
                    install()
                }
                .allowsHitTesting(false)
            )
            .onDisappear { context.removeMonitor() }
    }

    private func install() {
        context.removeMonitor()
        let context = self.context
        context.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard let view = context.view,
                  let window = view.window,
                  event.window === window
            else { return event }
            // The reader sits in this view's background, so its own frame is the
            // region to spare — a click inside it belongs to the content.
            let frame = view.convert(view.bounds, to: nil)
            if !frame.contains(event.locationInWindow) {
                action()
            }
            return event
        }
    }
}

extension View {
    /// Sheet contents only: closes the sheet when its parent window is clicked.
    func dismissesOnOutsideClick() -> some View {
        modifier(DismissOnOutsideClick())
    }

    /// For in-window surfaces (not sheets): runs `action` when a click lands
    /// anywhere in the same window outside this view's bounds.
    func onOutsideClick(perform action: @escaping () -> Void) -> some View {
        modifier(OutsideClickCatcher(action: action))
    }
}
