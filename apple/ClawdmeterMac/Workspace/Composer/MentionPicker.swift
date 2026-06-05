import SwiftUI
import ClawdmeterShared

/// `@`-triggered popover. Scope-cut per Codex P1 finding:
/// shows (a) other open sessions, (b) files the agent has already cited
/// in this session (`SourceEntry`s), (c) recent JSONLs across sessions.
/// A full repo-file walker is deferred to a follow-up TODO.
struct MentionPicker: View {

    let openSessions: [AgentSession]
    let sourceEntries: [SourceEntry]
    let recentJSONLs: [RecentSession]
    @Binding var query: String
    let onSelect: (Suggestion) -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex: Int = 0

    enum Suggestion: Identifiable, Hashable {
        case session(AgentSession)
        case file(path: String, label: String)
        case recent(RecentSession)

        var id: String {
            switch self {
            case .session(let s): return "s:\(s.id.uuidString)"
            case .file(let path, _): return "f:\(path)"
            case .recent(let r): return "r:\(r.path)"
            }
        }
        var label: String {
            switch self {
            case .session(let s): return s.goal ?? s.repoDisplayName
            case .file(_, let label): return label
            case .recent(let r): return r.firstPrompt ?? r.path
            }
        }
        var sublabel: String {
            switch self {
            case .session(let s): return "\(s.agent.rawValue.capitalized) · session"
            case .file(let path, _): return path
            case .recent(let r): return "Recent JSONL · \(r.provider.rawValue.capitalized)"
            }
        }
        var icon: String {
            switch self {
            case .session: return "bubble.left.and.bubble.right"
            case .file: return "doc"
            case .recent: return "clock.arrow.circlepath"
            }
        }
    }

    var filtered: [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var all: [Suggestion] = []
        all.append(contentsOf: openSessions.map { .session($0) })
        all.append(contentsOf: sourceEntries.map { .file(path: $0.payload, label: $0.label) })
        all.append(contentsOf: recentJSONLs.map { .recent($0) })
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.label.lowercased().contains(q) || $0.sublabel.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "at")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Mention")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(filtered.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if filtered.isEmpty {
                Text("No matches in open sessions, agent-cited files, or recent JSONLs. Full repo file walker is in TODOS.md.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { (idx, item) in
                            row(item, isSelected: idx == selectedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture { onSelect(item) }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 460)
        .background(ContinuumTokens.surface3, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .background(KeyMonitor(
            up: { selectedIndex = max(0, selectedIndex - 1) },
            down: { selectedIndex = min(max(0, filtered.count - 1), selectedIndex + 1) },
            enter: { if let pick = pickerAt(selectedIndex) { onSelect(pick) } },
            escape: onDismiss
        ))
    }

    private func pickerAt(_ idx: Int) -> Suggestion? {
        guard idx >= 0, idx < filtered.count else { return nil }
        return filtered[idx]
    }

    @ViewBuilder
    private func row(_ item: Suggestion, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: item.icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.sublabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .padding(.horizontal, 4)
    }
}
