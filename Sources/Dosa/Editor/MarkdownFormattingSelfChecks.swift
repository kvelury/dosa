import Foundation

/// In-process checks for the formatting actions. Invoked by
/// `DosaCalendarChecks` because this repo has no XCTest — see
/// `ContrastSelfChecks` for the sibling pattern.
///
/// Worth having as checks rather than eyeballing: every case here is one the
/// toolbar and the Format menu both route through, and the toggles are the kind
/// of text surgery that silently starts eating a character at the edges.
public enum MarkdownFormattingSelfChecks {
    public static func run() -> Int {
        var failures = 0

        func expect(_ actual: String?, _ expected: String, _ what: String, line: Int = #line) {
            guard actual != expected else { return }
            failures += 1
            fputs(
                "FAIL MarkdownFormattingSelfChecks.swift:\(line): \(what) — "
                    + "expected \(expected.debugDescription), got \(actual?.debugDescription ?? "nil")\n",
                stderr
            )
        }

        func expect(_ actual: NSRange?, _ expected: NSRange, _ what: String, line: Int = #line) {
            guard actual != expected else { return }
            failures += 1
            fputs(
                "FAIL MarkdownFormattingSelfChecks.swift:\(line): \(what) — "
                    + "expected \(NSStringFromRange(expected)), got "
                    + "\(actual.map(NSStringFromRange) ?? "nil")\n",
                stderr
            )
        }

        func expectNil(_ actual: MarkdownFormatting.Edit?, _ what: String, line: Int = #line) {
            guard actual != nil else { return }
            failures += 1
            fputs("FAIL MarkdownFormattingSelfChecks.swift:\(line): \(what) — expected no edit\n", stderr)
        }

        // MARK: Inline

        var text = "hello world"
        var edit = MarkdownFormatting.toggleInline(.bold, in: text, selection: NSRange(location: 6, length: 5))
        expect(applying(edit, to: text), "hello **world**", "bold wraps the selection")
        // The selection keeps covering the word, not the markers.
        expect(edit?.selection, NSRange(location: 8, length: 5), "bold keeps the word selected")

        text = "hello **world**"
        edit = MarkdownFormatting.toggleInline(.bold, in: text, selection: NSRange(location: 8, length: 5))
        expect(applying(edit, to: text), "hello world", "bold unwraps when markers surround the selection")
        expect(edit?.selection, NSRange(location: 6, length: 5), "unwrapped selection re-covers the word")

        edit = MarkdownFormatting.toggleInline(.bold, in: text, selection: NSRange(location: 6, length: 9))
        expect(applying(edit, to: text), "hello world", "bold unwraps when the selection includes the markers")

        text = "ab"
        edit = MarkdownFormatting.toggleInline(.bold, in: text, selection: NSRange(location: 1, length: 0))
        expect(applying(edit, to: text), "a****b", "bold with no selection inserts empty markers")
        expect(edit?.selection, NSRange(location: 3, length: 0), "caret lands between the markers")

        // Underscore, not asterisk: a `*` italic marker collides with `*`
        // bullets, which is why the generation prompt bans bare asterisks too.
        edit = MarkdownFormatting.toggleInline(.italic, in: "word", selection: NSRange(location: 0, length: 4))
        expect(applying(edit, to: "word"), "_word_", "italic uses underscores")

        for style in [MarkdownFormatting.InlineStyle.strikethrough, .code] {
            let on = MarkdownFormatting.toggleInline(style, in: "word", selection: NSRange(location: 0, length: 4))
            let wrapped = applying(on, to: "word") ?? ""
            let off = MarkdownFormatting.toggleInline(
                style, in: wrapped, selection: NSRange(location: 0, length: (wrapped as NSString).length)
            )
            expect(applying(off, to: wrapped), "word", "\(style.marker) round-trips")
        }

        text = "see docs"
        edit = MarkdownFormatting.insertLink(in: text, selection: NSRange(location: 4, length: 4))
        expect(applying(edit, to: text), "see [docs]()", "link wraps the selection")
        expect(edit?.selection, NSRange(location: 11, length: 0), "link parks the caret in the URL slot")

        expectNil(
            MarkdownFormatting.toggleInline(.bold, in: "ab", selection: NSRange(location: 5, length: 1)),
            "an out-of-bounds selection is rejected"
        )

        // MARK: Block

        text = "one\ntwo\nthree"
        edit = MarkdownFormatting.toggleBlock(.bulletList, in: text, selection: NSRange(location: 0, length: 7))
        expect(applying(edit, to: text), "- one\n- two\nthree", "bullets mark every touched line")

        edit = MarkdownFormatting.toggleBlock(.numberedList, in: text, selection: NSRange(location: 0, length: 13))
        expect(applying(edit, to: text), "1. one\n2. two\n3. three", "numbered list numbers sequentially")

        text = "- one\n- two"
        edit = MarkdownFormatting.toggleBlock(.bulletList, in: text, selection: NSRange(location: 0, length: 11))
        expect(applying(edit, to: text), "one\ntwo", "bullets clear when every line already has one")

        // Switching block style replaces the marker instead of stacking markers.
        text = "- one"
        edit = MarkdownFormatting.toggleBlock(.numberedList, in: text, selection: NSRange(location: 0, length: 5))
        expect(applying(edit, to: text), "1. one", "block styles replace each other")

        text = "- [ ] one"
        let taskSelection = NSRange(location: 0, length: 9)
        expect(
            applying(MarkdownFormatting.toggleBlock(.taskList, in: text, selection: taskSelection), to: text),
            "one",
            "task toggles itself off"
        )
        expect(
            applying(MarkdownFormatting.toggleBlock(.bulletList, in: text, selection: taskSelection), to: text),
            "- one",
            "bullet converts a task rather than treating it as already bulleted"
        )

        text = "## title"
        let headingSelection = NSRange(location: 0, length: 8)
        expect(
            applying(MarkdownFormatting.toggleBlock(.heading(2), in: text, selection: headingSelection), to: text),
            "title",
            "heading toggles off at its own level"
        )
        expect(
            applying(MarkdownFormatting.toggleBlock(.heading(1), in: text, selection: headingSelection), to: text),
            "# title",
            "a different heading level replaces rather than clears"
        )

        text = "    quoted"
        edit = MarkdownFormatting.toggleBlock(.blockquote, in: text, selection: NSRange(location: 0, length: 10))
        expect(applying(edit, to: text), "    > quoted", "blockquote keeps the line's indent")

        // MARK: Indent

        text = "- one\n- two"
        edit = MarkdownFormatting.indent(in: text, selection: NSRange(location: 0, length: 11), outdent: false)
        expect(applying(edit, to: text), "    - one\n    - two", "indent adds one unit per selected line")

        text = "    - one"
        edit = MarkdownFormatting.indent(in: text, selection: NSRange(location: 0, length: 9), outdent: true)
        expect(applying(edit, to: text), "- one", "outdent removes one unit of spaces")

        text = "\t- one"
        edit = MarkdownFormatting.indent(in: text, selection: NSRange(location: 0, length: 6), outdent: true)
        expect(applying(edit, to: text), "- one", "outdent removes a single tab")

        // A caret on a plain line just gets spaces — indenting the whole line
        // there would move text the user did not select.
        text = "hello"
        edit = MarkdownFormatting.indent(in: text, selection: NSRange(location: 5, length: 0), outdent: false)
        expect(applying(edit, to: text), "hello    ", "a caret on a plain line gets spaces")

        text = "- hello"
        edit = MarkdownFormatting.indent(in: text, selection: NSRange(location: 7, length: 0), outdent: false)
        expect(applying(edit, to: text), "    - hello", "a caret on a list line indents the line")

        expectNil(
            MarkdownFormatting.indent(in: "- one", selection: NSRange(location: 0, length: 5), outdent: true),
            "outdent at column zero is a no-op"
        )

        return failures
    }

    private static func applying(_ edit: MarkdownFormatting.Edit?, to text: String) -> String? {
        guard let edit else { return nil }
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit.range, with: edit.replacement)
        return result as String
    }
}
