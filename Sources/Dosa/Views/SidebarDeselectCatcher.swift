import SwiftUI
import AppKit

/// SwiftUI's sidebar List does not clear its selection when the user clicks empty
/// space between/below rows. This zero-size background view installs a local mouse
/// monitor and fires `onEmptyClick` when a click lands on a table view but not on
/// any row. The sidebar list is the only NSTableView in the main window (the detail
/// pane hosts no tables), so no further scoping is needed.
struct SidebarDeselectCatcher: NSViewRepresentable {
    let onEmptyClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onEmptyClick = onEmptyClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onEmptyClick = onEmptyClick
    }

    final class MonitorView: NSView {
        var onEmptyClick: (() -> Void)?
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
            var clickedRow = false
            var clickedTable = false
            while let current = view {
                if current is NSTableRowView { clickedRow = true }
                if current is NSTableView {
                    clickedTable = true
                    break
                }
                view = current.superview
            }
            if clickedTable && !clickedRow {
                DispatchQueue.main.async { [weak self] in
                    self?.onEmptyClick?()
                }
            }
        }
    }
}
