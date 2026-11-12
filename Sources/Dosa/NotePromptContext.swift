import Foundation

/// The "Note type" guidance substituted into the notes prompt's
/// `{{template_context}}` placeholder (the name predates this type and is kept
/// because customized prompts reference it). A plain note gets the general
/// meeting sections; an Interview-mode note gets question-by-question sections
/// built around the user's interview doc. Either way the objectivity rule is
/// appended, so the notes stay a factual record — scoring lives in the separate
/// scorecard call (`AppSettings.interviewScorecardPrompt`), never in the notes.
enum NotePromptContext {
    static func context(for note: Note) -> String {
        let base: String
        if let interview = note.interview {
            base = interviewContext(doc: interview.sourceDoc)
        } else {
            base = defaultContext
        }
        return base + "\n\n" + objectivityRule
    }

    static let defaultContext = """
    This is a general meeting note. Use these sections: "## Summary" (2-3 sentences max), \
    "## Key Points", "## Decisions", and "## Action Items" (as a checkbox list).
    """

    /// `{{user_name}}` is left in on purpose: `GenerationManager` substitutes the
    /// note-type context before it substitutes the user's name.
    static func interviewContext(doc: String) -> String {
        """
        This is a job interview that {{user_name}} is conducting; the other participant(s) are the \
        candidate. The user's manual notes are organized by the interview questions ("## Q1. …", \
        "## Q2. …"). Keep every one of those question headings, in their original order and wording. \
        Under each, record what the candidate said in answer to that question, filling in whatever the \
        user left blank, and attribute claims to the candidate rather than stating them as fact — write \
        "said they led the migration", not "led the migration". Capture specifics: projects, numbers, \
        technologies, timelines. For a question that was not asked in the interview, keep its heading \
        with a single bullet: "- Not covered in the interview." Put anything discussed outside the \
        questions under "## Other Discussion", and what the candidate asked (with the answers given) \
        under "## Candidate's Questions"; omit either section if there is nothing for it. These \
        question headings take the place of the usual Summary / Key Points / Decisions sections.

        The interview document below (questions, rubric, scoring guidance) is reference material only. \
        Use it to understand what each question is probing, but do not copy rubric text, criteria, or \
        scores into the notes.
        ---
        \(doc)
        ---
        """
    }

    /// Appended to every note's context by `context(for:)`. Kept in code rather
    /// than anywhere editable: no note type should be able to turn a record of
    /// what was said into a verdict on it. Interview scoring is a separate,
    /// explicitly-labelled output, so this still holds for interview notes.
    static let objectivityRule = """
    Whatever those sections are called, the notes are a factual record, not an evaluation. Do not \
    rate, score, grade, or conclude anything of your own, and do not comment on how the conversation \
    went or on how anyone performed. A section that asks for an assessment — strengths, concerns, \
    signals, a recommendation — may only carry assessments a participant actually made out loud or \
    that the user wrote in their manual notes, attributed to whoever made them. If there are none, \
    omit that section rather than supplying your own.
    """
}
