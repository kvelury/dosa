import SwiftUI
import AppKit

/// Interview mode's setup: paste or upload the questions/rubric doc. Used to
/// start a new interview note, to switch an existing note into Interview mode,
/// and to edit the doc later (before notes are generated).
struct InterviewSetupSheet: View {
    enum Mode: Identifiable {
        /// ＋▾ → New Interview…
        case create
        /// ⋯ → Switch to Interview Mode…
        case convert
        /// ⋯ → Edit Interview Doc… — replaces the rubric only, no extraction.
        case edit

        var title: String {
            switch self {
            case .create: return "New Interview"
            case .convert: return "Switch to Interview Mode"
            case .edit: return "Edit Interview Doc"
            }
        }

        var confirmTitle: String {
            switch self {
            case .create, .convert: return "Start Interview"
            case .edit: return "Save"
            }
        }

        var explanation: String {
            switch self {
            case .create, .convert:
                return "Paste or upload your interview questions and rubric. Dosa adds each question to your notes so you can fill in answers as you go, and keeps the full doc beside your notes. After the interview, Dosa scores the candidate's answers against the rubric."
            case .edit:
                return "Changes update the rubric beside your notes and what Dosa scores against. The question headings already in your notes stay as they are."
            }
        }

        var extractsQuestions: Bool { self != .edit }

        var id: Self { self }
    }

    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    var initialDoc = ""
    var initialFileName: String?
    let onComplete: (InterviewSetup) -> Void

    @State private var doc = ""
    @State private var fileName: String?
    @State private var errorText: String?
    @State private var working = false
    @State private var task: Task<Void, Never>?

    private var trimmedDoc: String { doc.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode.title)
                .appFont(.title2)
                .fontWeight(.semibold)
            Text(mode.explanation)
                .appFont(.callout)
                .foregroundStyle(Theme.secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: upload) {
                    Label("Upload Document…", systemImage: "doc.badge.plus")
                }
                .disabled(working)
                .help("Choose a .txt, .md, .pdf, .docx, or .rtf file")
                if let fileName {
                    Label(fileName, systemImage: "doc.text")
                        .appFont(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            TextEditor(text: $doc)
                .appFont(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.current.editorBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.35)) // system-color: field border, not text
                )
                .overlay(alignment: .topLeading) {
                    if doc.isEmpty {
                        Text("Paste your questions and rubric here…")
                            .appFont(.body)
                            .foregroundStyle(Theme.tertiaryTextColor)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 300)
                .disabled(working)
                .accessibilityLabel("Interview questions and rubric")
                .onChange(of: doc) { _, newValue in
                    if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fileName = nil }
                    errorText = nil
                }

            if let errorText {
                Text(errorText)
                    .appFont(.callout)
                    .foregroundStyle(Theme.current.warningTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if working {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding the questions…")
                        .appFont(.callout)
                        .foregroundStyle(Theme.secondaryTextColor)
                }
                Spacer()
                Button("Cancel") {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(mode.confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedDoc.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 620)
        .appFontScope()
        .onAppear {
            doc = initialDoc
            fileName = initialFileName
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = InterviewDocument.supportedTypes
        panel.allowsMultipleSelection = false
        panel.title = "Upload Interview Doc"
        panel.prompt = "Upload"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try InterviewDocument.readText(from: url)
            doc = text
            fileName = url.lastPathComponent
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func confirm() {
        let source = trimmedDoc
        guard !source.isEmpty else { return }
        guard source.count <= InterviewDocument.maxCharacters else {
            errorText = "This doc is too long (over \(InterviewDocument.maxCharacters / 1000)K characters). Trim it to the questions and rubric."
            return
        }
        let name = fileName
        guard mode.extractsQuestions else {
            onComplete(InterviewSetup(sourceDoc: source, sourceFileName: name, questions: []))
            dismiss()
            return
        }
        working = true
        task = Task {
            let questions = await InterviewDocument.extractQuestions(
                doc: source,
                generateText: GenerationManager.defaultTextGenerator()
            )
            working = false
            guard !Task.isCancelled else { return }
            onComplete(InterviewSetup(sourceDoc: source, sourceFileName: name, questions: questions))
            dismiss()
        }
    }
}
