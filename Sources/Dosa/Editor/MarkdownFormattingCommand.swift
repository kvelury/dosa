import SwiftUI
import AppKit
import MarkdownEngine

/// Every formatting action the toolbar and the Format menu can perform. One
/// enum so the two surfaces can never drift apart on what a button does.
enum MarkdownFormattingAction: Hashable, Identifiable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case heading(Int)
    case bulletList
    case numberedList
    case taskList
    case blockquote
    case indent
    case outdent
    case link

    var id: Self { self }

    var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .inlineCode: return "Code"
        case .heading(let level): return "Heading \(level)"
        case .bulletList: return "Bulleted List"
        case .numberedList: return "Numbered List"
        case .taskList: return "Task List"
        case .blockquote: return "Quote"
        case .indent: return "Indent"
        case .outdent: return "Outdent"
        case .link: return "Link"
        }
    }

    var symbol: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .inlineCode: return "chevron.left.forwardslash.chevron.right"
        case .heading: return "textformat.size"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .taskList: return "checklist"
        case .blockquote: return "text.quote"
        case .indent: return "increase.indent"
        case .outdent: return "decrease.indent"
        case .link: return "link"
        }
    }

    fileprivate func edit(in text: String, selection: NSRange) -> MarkdownFormatting.Edit? {
        switch self {
        case .bold: return MarkdownFormatting.toggleInline(.bold, in: text, selection: selection)
        case .italic: return MarkdownFormatting.toggleInline(.italic, in: text, selection: selection)
        case .strikethrough: return MarkdownFormatting.toggleInline(.strikethrough, in: text, selection: selection)
        case .inlineCode: return MarkdownFormatting.toggleInline(.code, in: text, selection: selection)
        case .heading(let level): return MarkdownFormatting.toggleBlock(.heading(level), in: text, selection: selection)
        case .bulletList: return MarkdownFormatting.toggleBlock(.bulletList, in: text, selection: selection)
        case .numberedList: return MarkdownFormatting.toggleBlock(.numberedList, in: text, selection: selection)
        case .taskList: return MarkdownFormatting.toggleBlock(.taskList, in: text, selection: selection)
        case .blockquote: return MarkdownFormatting.toggleBlock(.blockquote, in: text, selection: selection)
        case .indent: return MarkdownFormatting.indent(in: text, selection: selection, outdent: false)
        case .outdent: return MarkdownFormatting.indent(in: text, selection: selection, outdent: true)
        case .link: return MarkdownFormatting.insertLink(in: text, selection: selection)
        }
    }
}

/// Applies a `MarkdownFormattingAction` to whichever note editor has focus.
///
/// The target is resolved from the responder chain rather than held as state:
/// a shortcut can fire while any view is focused, and the Format menu must stay
/// disabled unless the thing being typed into is actually one of our editors.
enum MarkdownFormattingCommand {

    /// The focused note editor, or nil when focus is elsewhere (a text field, a
    /// list) or the editor is read-only.
    static var focusedEditor: NSTextView? {
        guard let responder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder else { return nil }
        guard let textView = responder as? NSTextView else { return nil }
        // The engine's coordinator is the delegate on every Dosa editor, and on
        // nothing else — field editors and other text views fail this check.
        guard textView.delegate is NativeTextViewCoordinator, textView.isEditable else { return nil }
        return textView
    }

    static var canFormat: Bool { focusedEditor != nil }

    static func perform(_ action: MarkdownFormattingAction) {
        guard let textView = focusedEditor else { return }
        apply(action, to: textView)
    }

    static func apply(_ action: MarkdownFormattingAction, to textView: NSTextView) {
        guard let edit = action.edit(in: textView.string, selection: textView.selectedRange()) else { return }
        // One shouldChange/didChange pair per action, so undo takes the whole
        // thing back in a single step and the engine restyles once.
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textView.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.didChangeText()
        let length = (textView.string as NSString).length
        let location = min(edit.selection.location, length)
        let clamped = NSRange(location: location, length: min(edit.selection.length, length - location))
        textView.setSelectedRange(clamped)
    }
}
