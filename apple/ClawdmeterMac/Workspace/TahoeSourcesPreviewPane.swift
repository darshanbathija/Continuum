import SwiftUI
import AppKit
import ClawdmeterShared

struct TahoeSourcesPreviewPane: View {
    @Environment(\.tahoe) private var t
    let chatStore: SessionChatStore?

    private var entries: [SourceEntry] {
        Array((chatStore?.snapshot.sourceEntries ?? []).prefix(14))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    TahoeEmptyReviewState(icon: "search", title: "No sources yet", body: "Files and URLs referenced by tools will appear here.")
                        .padding(16)
                } else {
                    ForEach(entries) { entry in
                        Button(action: { open(entry) }) {
                            HStack(alignment: .top, spacing: 10) {
                                TahoeIcon(entry.kind == .url ? "link" : "doc", size: 13)
                                    .foregroundStyle(t.accent)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.label)
                                        .font(TahoeFont.mono(11.5))
                                        .foregroundStyle(t.fg)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(entry.kind == .url ? "Fetched URL" : "Referenced \(entry.count)x")
                                        .font(TahoeFont.body(11))
                                        .foregroundStyle(t.fg3)
                                }
                                Spacer(minLength: 6)
                                if entry.count > 1 {
                                    Text("×\(entry.count)")
                                        .font(TahoeFont.mono(10.5, weight: .bold))
                                        .foregroundStyle(t.fg3)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 10)
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func open(_ entry: SourceEntry) {
        switch entry.kind {
        case .url:
            if let url = URL(string: entry.payload) {
                NSWorkspace.shared.open(url)
            }
        case .file:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.payload)])
        }
    }
}
