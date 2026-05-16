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
struct SourcesPane: View {
    let session: AgentSession
    @ObservedObject var chatStore: SessionChatStore

    var body: some View {
        let entries = collectEntries()
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

    private func row(_ entry: SourceEntry) -> some View {
        Button(action: { entry.open() }) {
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
        .buttonStyle(.plain)
    }

    // MARK: - Aggregation

    enum EntryKind { case file, url }

    struct SourceEntry: Identifiable {
        let id: String
        let kind: EntryKind
        let label: String
        let payload: String
        let count: Int
        let icon: String
        let tint: Color
        let open: () -> Void
    }

    private func collectEntries() -> [SourceEntry] {
        var files: [String: Int] = [:]
        var urls: [String: Int] = [:]
        let repoCwd = session.worktreePath ?? session.repoKey

        for msg in chatStore.messages where msg.kind == .toolCall {
            switch msg.title {
            case "Read", "Edit", "Write":
                let path = msg.body.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { continue }
                files[path, default: 0] += 1
            case "Glob", "Grep":
                let pattern = msg.body.trimmingCharacters(in: .whitespaces)
                guard !pattern.isEmpty else { continue }
                files[pattern, default: 0] += 1
            case "WebFetch", "WebSearch":
                let url = msg.body.trimmingCharacters(in: .whitespaces)
                guard !url.isEmpty else { continue }
                urls[url, default: 0] += 1
            default:
                break
            }
        }

        var out: [SourceEntry] = []
        for (path, count) in files.sorted(by: { $0.value > $1.value }) {
            let absolute: String
            if path.hasPrefix("/") { absolute = path }
            else { absolute = (repoCwd as NSString).appendingPathComponent(path) }
            out.append(SourceEntry(
                id: "f:\(path)",
                kind: .file,
                label: path,
                payload: absolute,
                count: count,
                icon: "doc.text",
                tint: .blue,
                open: {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: absolute)]
                    )
                }
            ))
        }
        for (url, count) in urls.sorted(by: { $0.value > $1.value }) {
            out.append(SourceEntry(
                id: "u:\(url)",
                kind: .url,
                label: url,
                payload: url,
                count: count,
                icon: "globe",
                tint: .purple,
                open: {
                    if let parsed = URL(string: url) {
                        NSWorkspace.shared.open(parsed)
                    }
                }
            ))
        }
        return out
    }
}
