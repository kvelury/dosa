import SwiftUI

/// Live audio-level bars shown in the floating bar while recording, so the
/// user can see that real audio is being picked up.
struct RecordingWaveformView: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(.red)
                    .frame(width: 3, height: 4 + CGFloat(min(max(level, 0), 1)) * 16)
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.12), value: levels)
    }
}

/// Shown in the detail pane when multiple sidebar notes are selected.
struct MultiSelectionView: View {
    let count: Int

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("\(count) notes selected")
                .font(.title2.weight(.semibold))
            Text("Right-click the selection in the sidebar to pin, move, or delete these notes together, or drag them into a folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.current.editorBackgroundColor)
    }
}

/// Error dialog with a friendly summary and a collapsed, expandable section
/// containing the raw API/server response for debugging.
struct ErrorDialogView: View {
    @Environment(\.dismiss) private var dismiss
    let message: String
    let detail: String?

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text("Something went wrong")
                    .font(.headline)
                Spacer()
            }

            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let detail, !detail.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    ScrollView {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
                } label: {
                    Text(showDetails ? "Hide technical details" : "Show technical details")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation {
                                showDetails.toggle()
                            }
                        }
                }
            }

            HStack {
                Spacer()
                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
