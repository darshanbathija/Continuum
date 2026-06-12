import SwiftUI
import AppKit
import ClawdmeterShared

/// G9 / Sources tab. Lists every file the agent has Read/Grepped/Globbed
/// + every URL fetched. Click → reveal in Finder (file) or open in browser
/// (URL).
///
/// Derived purely from the chat store's `tool_call` messages. We bucket by
/// title (Read/Grep/Glob/WebFetch/WebSearch) and count repeat references so
/// the user can see which files the agent leaned on hardest.
///
/// A5 — binds to `messagesSlice` (the per-transcript-append slice on
/// SessionChatStore) instead of the fat store. The pane invalidates
/// on staging commits that produce new tool-call source entries; it
/// does NOT re-render when only token usage updates or the permission
/// prompt flips.
struct SourcesPane: View {
    let session: AgentSession
    @ObservedObject var messagesSlice: ChatMessagesSlice

    init(session: AgentSession, chatStore: SessionChatStore) {
        self.session = session
        _messagesSlice = ObservedObject(wrappedValue: chatStore.messagesSlice)
    }

    var body: some View {
        // T9: precomputed in StagingParser; zero per-render work here.
        let snapshotEntries = messagesSlice.sourceEntries
        let entries = snapshotEntries.map { e in render(entry: e) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    emptyState
                } else {
                    Text("Files referenced")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                    ForEach(entries.filter { $0.kind == .file }) { entry in
                        row(entry)
                    }
                    let urls = entries.filter { $0.kind == .url }
                    if !urls.isEmpty {
                        Text("URLs fetched")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 14)
                        ForEach(urls) { entry in
                            row(entry)
                        }
                    }
                }
            }
            .padding(.bottom, 14)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("No sources yet")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func row(_ entry: RenderedSourceEntry) -> some View {
        Button(action: ContinuumAnalytics.wrapButton(
                "sources_open_entry",
                {
 entry.open() 
                }
            )) {
            HStack(spacing: 8) {
                Image(systemName: entry.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(entry.tint)
                    .frame(width: 14)
                Text(entry.label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if entry.count > 1 {
                    Text("×\(entry.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - View-layer rendering of precomputed SourceEntry

    /// Mac-side rendering wrapper. Shared `SourceEntry` carries the
    /// precomputed data (file/url, label, payload, count); the Mac side
    /// adds the SF Symbol, tint Color, and the open closure that calls
    /// into NSWorkspace.
    struct RenderedSourceEntry: Identifiable {
        let id: String
        let kind: ClawdmeterShared.SourceEntry.Kind
        let label: String
        let count: Int
        let icon: String
        let tint: Color
        let open: () -> Void
    }

    /// Convert a Shared `SourceEntry` into a `RenderedSourceEntry` with
    /// UI styling + click behavior. Files resolve relative paths against
    /// the session's repo cwd; URLs open via NSWorkspace.
    private func render(entry: ClawdmeterShared.SourceEntry) -> RenderedSourceEntry {
        let repoCwd = session.effectiveCwd
        switch entry.kind {
        case .file:
            let absolute: String = entry.payload.hasPrefix("/")
                ? entry.payload
                : (repoCwd as NSString).appendingPathComponent(entry.payload)
            return RenderedSourceEntry(
                id: entry.id, kind: .file, label: entry.label,
                count: entry.count, icon: "doc.text", tint: .blue,
                open: {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: absolute)]
                    )
                }
            )
        case .url:
            return RenderedSourceEntry(
                id: entry.id, kind: .url, label: entry.label,
                count: entry.count, icon: "globe", tint: .purple,
                open: {
                    if let parsed = URL(string: entry.payload) {
                        NSWorkspace.shared.open(parsed)
                    }
                }
            )
        }
    }
}
