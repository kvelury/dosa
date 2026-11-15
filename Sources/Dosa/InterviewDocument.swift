import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Everything Interview mode does with the user's questions/rubric doc outside
/// the views: reading an uploaded file to text, pulling the question list out
/// of it, seeding the editor, and assembling exports that carry the scorecard.
enum InterviewDocument {
    enum ReadError: LocalizedError {
        case unsupported(String)
        case unreadable(String)
        case noText(String)
        case tooLong(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let name):
                return "\(name) isn't a supported document. Use a .txt, .md, .pdf, .docx, or .rtf file, or paste the text instead."
            case .unreadable(let name):
                return "Dosa couldn't read \(name). Try exporting it as .txt or .pdf, or paste the text instead."
            case .noText(let name):
                return "\(name) has no text Dosa can read — a scanned PDF is only images. Paste the text instead."
            case .tooLong(let name):
                return "\(name) is too long for an interview doc (over \(InterviewDocument.maxCharacters / 1000)K characters). Trim it to the questions and rubric."
            }
        }
    }

    /// Generous for any real questions + rubric doc, while keeping a stray
    /// book-length upload from being sent to the LLM with every generation.
    static let maxCharacters = 150_000

    /// The upload panel's allowed types. Markdown and .docx have no constant on
    /// `UTType`, so they're resolved from their extensions.
    static var supportedTypes: [UTType] {
        var types: [UTType] = [.plainText, .pdf, .rtf]
        for ext in ["md", "markdown", "docx"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    // MARK: - Reading files

    static func readText(from url: URL) throws -> String {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let text: String
        switch ext {
        case "txt", "text", "md", "markdown":
            guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable(name) }
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        case "pdf":
            guard let document = PDFDocument(url: url) else { throw ReadError.unreadable(name) }
            text = document.string ?? ""
        case "docx", "rtf":
            let type: NSAttributedString.DocumentType = ext == "docx" ? .officeOpenXML : .rtf
            guard let attributed = try? NSAttributedString(
                url: url,
                options: [.documentType: type],
                documentAttributes: nil
            ) else { throw ReadError.unreadable(name) }
            text = attributed.string
        default:
            throw ReadError.unsupported(name)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ReadError.noText(name) }
        guard trimmed.count <= maxCharacters else { throw ReadError.tooLong(name) }
        return trimmed
    }

    // MARK: - Question extraction

    static func extractionPrompt(doc: String) -> String {
        """
        Below is a document an interviewer prepared for an upcoming job interview. It may contain \
        interview questions, a rubric, scoring guidance, and other notes. List the questions the \
        interviewer intends to ask the candidate, in the order they appear. Prompts phrased as \
        instructions ("Tell me about a time…", "Walk me through…") count as questions. Copy each \
        question's wording as written — do not rephrase, number, or add anything. Do not include rubric \
        criteria, scoring levels, follow-up hints, or section headers unless they are themselves a \
        question to the candidate. Keep a question's sub-parts together as one question.

        Reply with only a JSON array of strings, for example ["First question?", "Second question?"]. \
        If the document contains no questions, reply [].

        Document:
        ---
        \(doc)
        ---
        """
    }

    /// One LLM call that pulls the question list out of the doc. Never throws:
    /// with no generator (no API key), a failed call, or an unparseable reply it
    /// falls back to `heuristicQuestions`, and an empty result simply means the
    /// editor starts empty — the doc still reaches the side panel and the LLM.
    static func extractQuestions(
        doc: String,
        generateText: ((String) async throws -> String)?
    ) async -> [String] {
        if let generateText,
           let raw = try? await generateText(extractionPrompt(doc: doc)),
           let parsed = parseQuestionList(raw), !parsed.isEmpty {
            return parsed
        }
        return heuristicQuestions(in: doc)
    }

    /// Lenient parse of the extraction reply: tolerates a code fence or a stray
    /// sentence around the array. Nil when no JSON string array can be found.
    static func parseQuestionList(_ raw: String) -> [String]? {
        guard let open = raw.firstIndex(of: "["),
              let close = raw.lastIndex(of: "]"),
              open < close else { return nil }
        let json = String(raw[open...close])
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let strings = array.compactMap { $0 as? String }
        guard strings.count == array.count else { return nil }
        return dedupe(strings.map(cleanQuestion).filter { !$0.isEmpty })
    }

    /// The no-LLM fallback: every line ending in "?", plus numbered or bulleted
    /// lines under a heading that mentions questions.
    static func heuristicQuestions(in doc: String) -> [String] {
        var results: [String] = []
        var inQuestionSection = false
        for rawLine in doc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let isMarkdownHeading = line.hasPrefix("#")
            let isListItem = line.range(of: #"^([-*•]|\d+[.)]|[Qq]\d+[.):])\s+"#, options: .regularExpression) != nil
            let isColonHeading = !isListItem && line.hasSuffix(":") && line.count < 60
            if isMarkdownHeading || isColonHeading {
                inQuestionSection = line.lowercased().contains("question")
                continue
            }
            if line.hasSuffix("?") || (inQuestionSection && isListItem) {
                let cleaned = cleanQuestion(line)
                if !cleaned.isEmpty { results.append(cleaned) }
            }
        }
        return dedupe(results)
    }

    /// Strips list markers and "Q1." style numbering, and folds a multi-line
    /// question onto one line so it fits a heading.
    static func cleanQuestion(_ text: String) -> String {
        var line = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Looped so stacked markers ("- Q3: …") come off together.
        while let range = line.range(of: #"^([-*•]|\d+[.)]|[Qq]\d+[.):]?)\s+"#, options: .regularExpression) {
            line.removeSubrange(range)
        }
        while line.hasPrefix("#") { line.removeFirst() }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func dedupe(_ questions: [String]) -> [String] {
        var seen = Set<String>()
        return questions.filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Editor seeding

    /// "## Q1. …" headings, each followed by an empty line to type the answer on.
    static func seedText(for questions: [String]) -> String {
        guard !questions.isEmpty else { return "" }
        return questions.enumerated()
            .map { "## Q\($0.offset + 1). \($0.element)\n" }
            .joined(separator: "\n\n")
    }

    /// The manual notes after seeding: the questions alone for an empty note,
    /// appended below anything the user already wrote otherwise.
    static func seededManualText(existing: String, questions: [String]) -> String {
        let seed = seedText(for: questions)
        guard !seed.isEmpty else { return existing }
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? seed : existing + "\n\n" + seed
    }

    // MARK: - Export

    /// The notes body shared by Export Notes and the Notion page: the Dosa notes
    /// (or manual notes), plus the scorecard when the note opts in.
    static func exportBody(for note: Note) -> String {
        var body = note.enhancedMarkdown ?? note.manualText
        if note.exportsScorecard,
           let scorecard = note.scorecardMarkdown,
           !scorecard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body += "\n\n# Dosa Scorecard\n\n" + scorecard
        }
        return body
    }
}

/// In-process checks for `InterviewDocument`'s text handling. Invoked by
/// `DosaCalendarChecks` because this repo has no XCTest — see
/// `ContrastSelfChecks` for the sibling pattern.
public enum InterviewSelfChecks {
    public static func run() -> Int {
        var failures = 0

        func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String, line: Int = #line) {
            guard actual != expected else { return }
            failures += 1
            fputs(
                "FAIL InterviewSelfChecks:\(line): \(what) — expected \(String(describing: expected)), "
                    + "got \(String(describing: actual))\n",
                stderr
            )
        }

        // MARK: Parsing the extraction reply

        expect(InterviewDocument.parseQuestionList(#"["What is X?", "Tell me about Y."]"#),
               ["What is X?", "Tell me about Y."], "plain JSON array")
        expect(InterviewDocument.parseQuestionList("```json\n[\"A?\", \"B?\"]\n```"),
               ["A?", "B?"], "fenced JSON array")
        expect(InterviewDocument.parseQuestionList("Here you go:\n[\"Q1. A?\", \"2) B?\"]"),
               ["A?", "B?"], "preamble and numbering stripped")
        expect(InterviewDocument.parseQuestionList("[\"A?\", \"a?\"]"), ["A?"], "case-insensitive dedupe")
        expect(InterviewDocument.parseQuestionList("[]"), [], "empty array is a valid reply")
        expect(InterviewDocument.parseQuestionList("no questions here"), nil, "no array → nil")
        expect(InterviewDocument.parseQuestionList("[\"A?\", 3]"), nil, "non-string element → nil")
        expect(InterviewDocument.parseQuestionList("[\"A?\""), nil, "unterminated array → nil")

        // MARK: Heuristic fallback

        let doc = """
        # Backend Engineer Loop

        ## Questions
        1. Walk me through a system you designed.
        2. How do you handle on-call?

        ## Rubric
        - 4: Strong, specific examples
        - 1: Vague
        Why did you apply?
        """
        expect(InterviewDocument.heuristicQuestions(in: doc),
               ["Walk me through a system you designed.", "How do you handle on-call?", "Why did you apply?"],
               "numbered lines under a Questions heading plus any line ending in ?")
        expect(InterviewDocument.heuristicQuestions(in: "Rubric:\n- 4: great\n- 1: poor"), [],
               "rubric-only doc yields no questions")

        // MARK: Seeding

        expect(InterviewDocument.seedText(for: ["A?", "B?"]), "## Q1. A?\n\n\n## Q2. B?\n", "seed headings")
        expect(InterviewDocument.seedText(for: []), "", "no questions → no seed")
        expect(InterviewDocument.seededManualText(existing: "  \n", questions: ["A?"]), "## Q1. A?\n",
               "empty note is replaced by the seed")
        expect(InterviewDocument.seededManualText(existing: "Prep notes", questions: ["A?"]),
               "Prep notes\n\n## Q1. A?\n", "seed is appended below existing notes")
        expect(InterviewDocument.seededManualText(existing: "Prep notes", questions: []), "Prep notes",
               "no questions leaves notes untouched")
        expect(InterviewDocument.cleanQuestion("- Q3: Tell me\n  about it"), "Tell me about it",
               "markers stripped and lines folded")

        // MARK: Export assembly

        var note = Note()
        note.manualText = "manual"
        note.enhancedMarkdown = "enhanced"
        note.scorecardMarkdown = "## Q1. A?\n**Score:** 3 / 4"
        expect(InterviewDocument.exportBody(for: note), "enhanced", "scorecard off by default")
        note.includeScorecardInExport = true
        expect(InterviewDocument.exportBody(for: note),
               "enhanced\n\n# Dosa Scorecard\n\n## Q1. A?\n**Score:** 3 / 4", "scorecard appended when on")
        note.scorecardMarkdown = "  "
        expect(InterviewDocument.exportBody(for: note), "enhanced", "blank scorecard is skipped")
        note.enhancedMarkdown = nil
        note.scorecardMarkdown = nil
        expect(InterviewDocument.exportBody(for: note), "manual", "falls back to manual notes")

        return failures
    }
}
