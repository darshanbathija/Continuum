import SwiftUI
import ClawdmeterShared
#if canImport(UIKit)
import UIKit
#endif

/// Compact Tahoe source list for the iOS Code workbench.
/// Uses only `WireChatSnapshot.sourceEntries`; URL rows open in Safari,
/// file rows copy the Mac path or send it back to the agent because those
/// paths are not present on iOS.
struct iOSSourcesPane: View {
    @Environment(\.tahoe) private var t
    @ObservedObject var chatStore: iOSChatStore
    var outbox: MobileCommandOutbox?
    var sessionId: UUID?
    @State private var copiedId: String?

    private var entries: [SourceEntry] {
        Array(chatStore.snapshot.sourceEntries.prefix(80))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if entries.isEmpty {
                    emptyState
                } else {
                    ForEach(entries) { entry in
                        sourceRow(entry)
                    }
                }
            }
            .padding(14)
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            TahoeIcon("search", size: 24)
                .foregroundStyle(t.fg4)
            Text("No sources yet")
                .font(TahoeFont.body(14, weight: .semibold))
                .foregroundStyle(t.fg2)
            Text("Files and URLs referenced by tool calls will appear here.")
                .font(TahoeFont.body(12))
                .foregroundStyle(t.fg3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func sourceRow(_ entry: SourceEntry) -> some View {
        Button {
            open(entry)
        } label: {
            TahoeGlass(radius: 6, tone: .chip, solid: t.dark ? true : nil) {
                HStack(alignment: .top, spacing: 11) {
                    TahoeIcon(entry.kind == .url ? "link" : "doc", size: 14)
                        .foregroundStyle(entry.kind == .url ? t.accent : t.fg3)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.label)
                            .font(TahoeFont.mono(12))
                            .foregroundStyle(t.fg)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(subtitle(for: entry))
                            .font(TahoeFont.body(11))
                            .foregroundStyle(t.fg3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(entry.count > 1 ? "x\(entry.count)" : (copiedId == entry.id ? "Copied" : "Open"))
                        .font(TahoeFont.mono(10.5, weight: .bold))
                        .foregroundStyle(t.fg4)
                }
                .padding(12)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy path", action: ContinuumAnalytics.wrapButton(
                    "copy_path",
                    {
 copy(entry.payload, id: entry.id) 
                    }
                ))
            if canSendToAgent {
                Button("Send to agent", action: ContinuumAnalytics.wrapButton(
                        "send_to_agent",
                        {
 sendToAgent(entry) 
                        }
                    ))
            }
            if entry.kind == .url, let url = URL(string: entry.payload) {
                Link("Open URL", destination: url)
            }
        }
    }

    private func subtitle(for entry: SourceEntry) -> String {
        switch entry.kind {
        case .url:
            return "Fetched URL"
        case .file:
            return "Mac path - tap to copy"
        }
    }

    private func open(_ entry: SourceEntry) {
        switch entry.kind {
        case .url:
            if let url = URL(string: entry.payload) {
                UIApplication.shared.open(url)
            }
        case .file:
            copy(entry.payload, id: entry.id)
        }
    }

    private func copy(_ text: String, id: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        copiedId = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedId == id { copiedId = nil }
        }
        #endif
    }

    private var canSendToAgent: Bool {
        outbox != nil && sessionId != nil
    }

    private func sendToAgent(_ entry: SourceEntry) {
        guard let outbox, let sessionId else { return }
        let noun = entry.kind == .url ? "URL" : "Mac workspace file"
        outbox.enqueueSend(
            sessionId: sessionId,
            text: "Please inspect this \(noun) from the iOS Code sources pane:\n\(entry.payload)",
            asFollowUp: true
        )
    }
}
