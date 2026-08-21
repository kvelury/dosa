import Foundation
import Combine

struct NoteTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Markdown scaffold copied into `Note.manualText` when the template is applied.
    var body: String
    /// Instructions substituted into the generation prompt's `{{template_context}}`.
    var promptContext: String
    /// Non-nil for the four shipped templates. Drives "Reset to Default" and lets
    /// "Restore Defaults" find a shipped template again after it was edited or
    /// deleted; nil means the user created this one. It confers no protection —
    /// built-ins are deletable like any other template.
    var builtInKey: String?
}

/// Deliberately NOT @MainActor — mirrors `NotesStore`, which is a plain ObservableObject
/// read from @MainActor code. Marking it @MainActor makes `TemplateStore.shared` in
/// DosaApp's property initializer an isolation warning for no benefit.
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()

    @Published var templates: [NoteTemplate] { didSet { persist() } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: AppSettings.noteTemplatesKey),
           let decoded = try? JSONDecoder().decode([NoteTemplate].self, from: data) {
            // An empty array is a real stored state now that built-ins can be
            // deleted — "I removed every template" has to survive a relaunch
            // rather than silently resurrecting the four shipped ones.
            templates = decoded
        } else {
            templates = Self.builtIns
            // Persisted immediately because `builtIns` mints fresh UUIDs on every
            // launch: without this, a note created from a built-in would lose its
            // templateId match — and with it the template's prompt context — the
            // next time the app started.
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        UserDefaults.standard.set(data, forKey: AppSettings.noteTemplatesKey)
    }

    func template(id: UUID?) -> NoteTemplate? {
        guard let id else { return nil }
        return templates.first { $0.id == id }
    }

    func add() -> NoteTemplate {
        let template = NoteTemplate(name: "New Template", body: "", promptContext: "")
        templates.append(template)
        return template
    }

    /// Deletes any template, shipped or user-made. A deleted built-in comes back
    /// through "Restore Defaults", which is why this needs no confirmation step.
    func delete(id: UUID) {
        templates.removeAll { $0.id == id }
    }

    func resetToDefault(id: UUID) {
        guard let index = templates.firstIndex(where: { $0.id == id }),
              let key = templates[index].builtInKey,
              let builtIn = Self.builtIns.first(where: { $0.builtInKey == key }) else { return }
        templates[index].name = builtIn.name
        templates[index].body = builtIn.body
        templates[index].promptContext = builtIn.promptContext
    }

    func restoreDefaults() {
        var next = templates
        for builtIn in Self.builtIns {
            if let index = next.firstIndex(where: { $0.builtInKey == builtIn.builtInKey }) {
                next[index].name = builtIn.name
                next[index].body = builtIn.body
                next[index].promptContext = builtIn.promptContext
            } else {
                next.append(builtIn)
            }
        }
        templates = next
    }

    func promptContext(for note: Note) -> String {
        var context = Self.defaultContext
        if let template = template(id: note.templateId) {
            context = template.promptContext
            let seed = note.templateSeed ?? ""
            if !seed.isEmpty {
                context += """


                The user's manual notes started from this template scaffold:
                ---
                \(seed)
                ---
                Headings from that scaffold with nothing written under them are empty structure, not content \
                the user wrote — drop those sections rather than preserving them. Rule 1's requirement to keep \
                the user's lines verbatim applies only to text they actually added.
                """
            }
        }
        return context + "\n\n" + Self.objectivityRule
    }

    static let defaultContext = """
    This is a general meeting note. Use these sections: "## Summary" (2-3 sentences max), \
    "## Key Points", "## Decisions", and "## Action Items" (as a checkbox list).
    """

    /// Appended to every note's context by `promptContext(for:)` — templated or not,
    /// shipped template or user-written one. Deliberately kept out of the editable
    /// template text: a template's job is to supply structure and context, and no
    /// template (or edit to one) should be able to turn a record of what was said
    /// into a verdict on it. Living here also means the rule reaches templates that
    /// were stored before it existed, which a change to `builtIns` alone would not.
    static let objectivityRule = """
    Whatever those sections are called, the notes are a factual record, not an evaluation. Do not \
    rate, score, grade, or conclude anything of your own, and do not comment on how the conversation \
    went or on how anyone performed. A section that asks for an assessment — strengths, concerns, \
    signals, a recommendation — may only carry assessments a participant actually made out loud or \
    that the user wrote in their manual notes, attributed to whoever made them. If there are none, \
    omit that section rather than supplying your own.
    """

    static let builtIns: [NoteTemplate] = [
        NoteTemplate(
            name: "Interview (Hiring)",
            body: """
            ## Candidate & Role
            - Candidate:
            - Role:
            - Interviewer(s):

            ## Background & Experience

            ## Focus Area / Technical Discussion

            ## Candidate's Questions

            ## Strengths

            ## Concerns

            ## Recommendation
            """,
            promptContext: """
            This is a job interview that {{user_name}} is conducting — they are the interviewer, \
            recruiting for a role, and the other participant is the candidate. Use these sections: \
            "## Candidate & Role" (a short bullet list — candidate, role, interviewers), \
            "## Background & Experience", "## Focus Area / Technical Discussion", "## Candidate's \
            Questions" (what the candidate asked and how it was answered), "## Strengths", \
            "## Concerns", and "## Recommendation". Attribute claims to the candidate rather than \
            stating them as fact — write "said they led the migration", not "led the migration". \
            Capture specifics: projects, numbers, technologies, timelines. The last three sections are \
            the interviewer's call, not yours: fill "## Strengths", "## Concerns", and \
            "## Recommendation" only from what {{user_name}} wrote in their manual notes or said in the \
            transcript, and drop any of them they left empty. Never add a strength, a concern, or a \
            hire/no-hire verdict of your own.
            """,
            builtInKey: "interviewHiring"
        ),
        NoteTemplate(
            name: "Interview (Job Search)",
            body: """
            ## Company & Role
            - Company:
            - Role:
            - Interviewer(s):

            ## What They Told Me

            ## Questions I Was Asked

            ## Questions I Asked

            ## Signals

            ## Follow-ups
            - [ ]
            """,
            promptContext: """
            This is a job interview in which {{user_name}} is the candidate — someone else is conducting \
            it. Write the notes from the candidate's point of view: what the user learned about the company \
            and the role, and what they need to do next. Use these sections: "## Company & Role" (a short \
            bullet list — company, role, interviewers), "## What They Told Me" (about the team, the work, \
            the process, compensation, timelines), "## Questions I Was Asked" (each with a brief note on how \
            the user answered), "## Questions I Asked" (and the answers given), "## Signals" (only things \
            {{user_name}} themselves flagged as encouraging or concerning in their manual notes — quote the \
            transcript line that goes with each, and drop the section if they flagged nothing), and \
            "## Follow-ups" (a checkbox list: thank-you notes, materials to send, things to research, dates \
            to chase). Attribute statements about the company to whoever made them. Do not grade the user's \
            performance, add encouragement, or say anything about how the interview went.
            """,
            builtInKey: "interviewJobSearch"
        ),
        NoteTemplate(
            name: "1:1",
            body: """
            ## Wins Since Last Time

            ## What's Blocking

            ## Feedback

            ## Career & Growth

            ## Action Items
            - [ ]
            """,
            promptContext: """
            This is a 1:1 between a manager and their direct report. Use these sections: "## Wins Since \
            Last Time", "## What's Blocking", "## Feedback" (in both directions — note who gave it to \
            whom), "## Career & Growth", and "## Action Items" (a checkbox list, each item with an owner). \
            Where someone said plainly how they felt — frustrated, excited, stretched thin — record it as \
            their own statement, attributed to them, because that is the substance of a 1:1. Never infer a \
            mood no one named, and never characterize the state of the relationship or the conversation. \
            Keep sensitive topics (compensation, performance, personal circumstances) factual and free of \
            editorializing.
            """,
            builtInKey: "oneOnOne"
        ),
        NoteTemplate(
            name: "Team Meeting",
            body: """
            ## Attendees

            ## Agenda

            ## Updates

            ## Discussion

            ## Decisions

            ## Action Items
            - [ ]

            ## Parking Lot
            """,
            promptContext: """
            This is a team meeting with several participants. Use these sections: "## Attendees", \
            "## Agenda", "## Updates" (grouped by person or workstream), "## Discussion" (the substantive \
            back-and-forth — note where people disagreed and how it resolved), "## Decisions" (each with who \
            made the call), "## Action Items" (a checkbox list, each with an owner and a due date if one was \
            given), and "## Parking Lot" (raised but deliberately deferred). Attribute updates, decisions, \
            and action items to specific people by name wherever the transcript makes the speaker clear.
            """,
            builtInKey: "teamMeeting"
        ),
    ]
}
