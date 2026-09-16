import SwiftUI

/// Where the note editor's formatting strip sits (Settings ▸ Appearance).
/// Top reads as a document toolbar; bottom folds it into the floating bar for
/// people who would rather keep one piece of chrome on screen.
enum FormattingToolbarPlacement: String, CaseIterable, Identifiable {
    case top
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top: return "Top of Editor"
        case .bottom: return "In Floating Bar"
        }
    }

    static func resolved(_ stored: String) -> FormattingToolbarPlacement {
        FormattingToolbarPlacement(rawValue: stored) ?? .top
    }
}

/// Bold/italic/lists/headings for the focused editor. Every button runs the same
/// `MarkdownFormattingAction` the keyboard shortcut does, so the two can't drift.
///
/// Rendered in whichever placement the user picked; `compact` is the floating-bar
/// variant, which drops the labels and tightens the spacing to fit beside the
/// record controls.
struct FormattingToolbar: View {
    var compact = false

    private static let inlineActions: [MarkdownFormattingAction] = [
        .bold, .italic, .strikethrough, .inlineCode
    ]
    private static let blockActions: [MarkdownFormattingAction] = [
        .bulletList, .numberedList, .taskList, .blockquote
    ]
    private static let indentActions: [MarkdownFormattingAction] = [.outdent, .indent]

    var body: some View {
        HStack(spacing: compact ? 2 : 4) {
            group(Self.inlineActions)
            divider
            headingMenu
            divider
            group(Self.blockActions)
            divider
            group(Self.indentActions)
            divider
            button(.link)
            if !compact { Spacer() }
        }
        .padding(.horizontal, compact ? 4 : 16)
        .padding(.vertical, compact ? 0 : 5)
        .buttonStyle(.plain)
    }

    private func group(_ actions: [MarkdownFormattingAction]) -> some View {
        ForEach(actions) { button($0) }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.tertiaryTextColor.opacity(0.35))
            .frame(width: 1, height: compact ? 14 : 16)
            .padding(.horizontal, compact ? 3 : 5)
            .accessibilityHidden(true)
    }

    private func button(_ action: MarkdownFormattingAction) -> some View {
        Button {
            MarkdownFormattingCommand.perform(action)
        } label: {
            Image(systemName: action.symbol)
                .appFont(.callout)
                .frame(width: compact ? 22 : 26, height: compact ? 20 : 24)
                .contentShape(Rectangle())
        }
        .help(action.title)
        .accessibilityLabel(action.title)
    }

    /// A menu rather than three buttons: heading levels are a single choice, and
    /// H1/H2/H3 side by side would take a third of the bar's width.
    private var headingMenu: some View {
        Menu {
            ForEach(1...3, id: \.self) { level in
                Button(MarkdownFormattingAction.heading(level).title) {
                    MarkdownFormattingCommand.perform(.heading(level))
                }
            }
        } label: {
            Image(systemName: MarkdownFormattingAction.heading(1).symbol)
                .appFont(.callout)
                .frame(width: compact ? 26 : 30, height: compact ? 20 : 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Heading")
        .accessibilityLabel("Heading level")
    }
}
