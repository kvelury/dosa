import SwiftUI

/// The right-hand pane of an Interview-mode note's My Notes view: the user's
/// questions/rubric doc, read-only. While a live-mode recording runs on the
/// note, a Rubric | Live Transcript switch in the header shares the pane with
/// the running transcript.
struct InterviewSidePanel: View {
    enum Tab: String, CaseIterable {
        case rubric = "Rubric"
        case live = "Live Transcript"
    }

    let interview: InterviewSetup
    let noteId: UUID
    @ObservedObject var live: LiveTranscriber
    /// True while this note is being recorded in live mode.
    let showsLiveTab: Bool
    var bottomContentInset: CGFloat = 0

    @State private var tab: Tab = .rubric

    private var showingLive: Bool { showsLiveTab && tab == .live }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(
                title: showingLive ? "Live Transcript" : (interview.sourceFileName ?? "Rubric"),
                systemImage: showingLive ? "text.bubble" : "checklist",
                copyText: { showingLive ? liveText : interview.sourceDoc }
            ) {
                if showsLiveTab {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { tab in
                            Text(tab.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Side panel")
                }
            }
            Divider()
            if showingLive {
                LiveTranscriptPane(live: live)
            } else {
                DosaMarkdownEditor(
                    text: .constant(interview.sourceDoc),
                    isEditable: false,
                    bottomContentInset: bottomContentInset,
                    documentId: "\(noteId)-rubric"
                )
                .accessibilityLabel("Interview rubric, read-only")
            }
        }
        .background(Theme.current.editorBackgroundColor)
        // Back to the rubric when the recording ends, so the pane never sits on
        // a tab that has disappeared.
        .onChange(of: showsLiveTab) { _, shows in
            if !shows { tab = .rubric }
        }
    }

    private var liveText: String {
        live.lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }
}
