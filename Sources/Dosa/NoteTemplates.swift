import Foundation
import Combine

struct NoteTemplate: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// Markdown scaffold copied into `Note.manualText` when the template is applied.
    var body: String
    /// Instructions substituted into the generation prompt's `{{template_context}}`.
    var promptContext: String
    /// Non-nil for the four shipped templates. Drives "Reset to Default" and keeps
    /// built-ins undeletable; nil means the user created this one.
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
           let decoded = try? JSONDecoder().decode([NoteTemplate].self, from: data),
           !decoded.isEmpty {
            templates = decoded
        } else {
            templates = Self.builtIns
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

    func delete(id: UUID) {
        guard templates.first(where: { $0.id == id })?.builtInKey == nil else { return }
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
        guard let template = template(id: note.templateId) else {
            return Self.defaultContext
        }
        let seed = note.templateSeed ?? ""
        guard !seed.isEmpty else { return template.promptContext }
        return template.promptContext + """


        The user's manual notes started from this template scaffold:
        ---
        \(seed)
        ---
        Headings from that scaffold with nothing written under them are empty structure, not content \
        the user wrote — drop those sections rather than preserving them. Rule 1's requirement to keep \
        the user's lines verbatim applies only to text they actually added.
        """
    }

    static let defaultContext = """
    This is a general meeting note. Use these sections: "## Summary" (2-3 sentences max), \
    "## Key Points", "## Decisions", and "## Action Items" (as a checkbox list).
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
            recruiting for a role, and the other participant is the candidate. Organize the notes around \
            evaluating that candidate. Use these sections: "## Candidate & Role" (a short bullet list — \
            candidate, role, interviewers), "## Background & Experience", "## Focus Area / Technical \
            Discussion", "## Candidate's Questions" (what the candidate asked and how it was answered), \
            "## Strengths" (each with a concrete example or the candidate's own words from the transcript), \
            "## Concerns", and "## Recommendation". Attribute claims to the candidate rather than stating \
            them as fact — write "said they led the migration", not "led the migration". Capture specifics: \
            projects, numbers, technologies, timelines. Under "## Recommendation" record only a verdict the \
            interviewer actually stated; if they did not state one, omit the section rather than inventing a \
            hire/no-hire call.
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

            ## Signals — Good & Bad

            ## Follow-ups
            - [ ]
            """,
            promptContext: """
            This is a job interview in which {{user_name}} is the candidate — someone else is conducting \
            it. Write the notes from the candidate's point of view: what the user learned about the company \
            and the role, and what they need to do next. Use these sections: "## Company & Role" (a short \
            bullet list — company, role, interviewers), "## What They Told Me" (about the team, the work, \
            the process, compensation, timelines), "## Questions I Was Asked" (each with a brief note on how \
            the user answered), "## Questions I Asked" (and the answers given), "## Signals — Good & Bad" \
            (concrete things said or done that are encouraging or concerning — never vibes or inference), \
            and "## Follow-ups" (a checkbox list: thank-you notes, materials to send, things to research, \
            dates to chase). Attribute statements about the company to whoever made them. Do NOT grade the \
            user's own performance or add encouragement — record what was said, not how well you think it went.
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
            This is a 1:1 between a manager and their direct report. Keep it personal and candid. Use these \
            sections: "## Wins Since Last Time", "## What's Blocking", "## Feedback" (in both directions — \
            note who gave it to whom), "## Career & Growth", and "## Action Items" (a checkbox list, each \
            item with an owner). Record how someone framed something when they said it plainly — \
            frustration, excitement, being stretched thin — because that is the substance of a 1:1, but \
            never speculate about how anyone felt. Keep sensitive topics (compensation, performance, \
            personal circumstances) factual and free of editorializing.
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
