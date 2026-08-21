import Foundation

struct Folder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var parentId: UUID?
}

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = ""
    var createdAt = Date()
    var folderId: UUID?
    var manualText = ""
    var enhancedMarkdown: String?
    var transcript: String?
    var recordingFileName: String?
    var recordingDuration: TimeInterval?
    var notionPageId: String?
    var notionPageURL: String?
    var calendarEventUID: String?
    var calendarEventInstanceStart: Date?
    var calendarHTMLLink: String?
    var calendarID: String?
    /// The meeting as it looked when this note was linked to it. The calendar only
    /// syncs 30 days forward, so the live event vanishes the moment the meeting
    /// ends — this is what the editor's meeting chip reads from afterwards.
    var calendarEventSnapshot: CalendarEvent?
    var pinnedAt: Date?
    var deletedAt: Date?
    /// Model and note-style used the last time Dosa generated notes for this
    /// note, for the editor header's sparkle pill hover card.
    var generationModel: String?
    var generationStyle: String?
    var templateId: UUID?
    var templateName: String?
    /// The template body as it was when applied. Lets generation tell scaffolding the user
    /// never filled in from lines they actually wrote, and keeps the note readable
    /// after the template is edited or deleted.
    var templateSeed: String?

    var isPinned: Bool { pinnedAt != nil }
    var isDeleted: Bool { deletedAt != nil }
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Note" : trimmed
    }
}

extension Note {
    /// What attaching new audio would destroy on this note, phrased for the prompt.
    /// Nil when the note is empty and the action is safe to run immediately.
    var existingWorkDescription: String? {
        let hasRecording = recordingFileName != nil
        let hasNotes = transcript != nil || enhancedMarkdown != nil
        switch (hasRecording, hasNotes) {
        case (true, true):   return "a recording and generated notes"
        case (true, false):  return "a recording"
        case (false, true):  return "generated notes"
        case (false, false): return nil
        }
    }
}

enum TimeFormatting {
    static func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func spoken(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }
}
