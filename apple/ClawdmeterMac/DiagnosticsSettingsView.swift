import SwiftUI
import ClawdmeterShared

/// Sessions v2 T17. Reader UI for the JSONL audit log under
/// `~/.clawdmeter/audit/`. Shows the most recent 200 entries per stream
/// (sends / swaps / autopilot) with filter + search. Mirrors dmux's logs
/// popup pattern.
struct DiagnosticsSettingsView: View {
    @State private var selectedKind: AuditKind = .sends
    @State private var entries: [AuditEntry] = []
    @State private var query: String = ""
    @State private var sessionFilter: String = ""
    @State private var refreshTick: Int = 0

    enum AuditKind: String, CaseIterable, Identifiable {
        case sends, swaps, autopilot
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sends: return "Prompt sends"
            case .swaps: return "Model / effort / mode swaps"
            case .autopilot: return "Autopilot toggles"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if filteredEntries.isEmpty {
                emptyState
            } else {
                entryList
            }
        }
        .padding(.vertical, 12)
        .frame(minWidth: 560, minHeight: 400)
        .task(id: refreshTick) { await reload() }
        .task(id: selectedKind) { await reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Stream", selection: $selectedKind) {
                    ForEach(AuditKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                Spacer()
                Button {
                    refreshTick += 1
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                TextField("Filter text", text: $query)
                    .textFieldStyle(.roundedBorder)
                TextField("Session ID", text: $sessionFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            HStack {
                Text("\(filteredEntries.count) / \(entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(auditFolderURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Button {
                    NSWorkspace.shared.open(auditFolderURL)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open audit folder in Finder")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(filteredEntries.enumerated()), id: \.offset) { _, entry in
                    AuditEntryRow(entry: entry)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No \(selectedKind.label.lowercased()) yet")
                .foregroundStyle(.secondary)
            if !query.isEmpty || !sessionFilter.isEmpty {
                Text("Try clearing the filters")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var filteredEntries: [AuditEntry] {
        let q = query.lowercased()
        let s = sessionFilter.lowercased()
        return entries.filter { entry in
            (q.isEmpty || entry.raw.lowercased().contains(q))
                && (s.isEmpty || entry.sessionId.lowercased().contains(s))
        }
    }

    private func reload() async {
        let lines = await AuditLog.shared.recentEntries(kind: selectedKind.rawValue, limit: 200)
        let parsed = lines.reversed().compactMap { AuditEntry(raw: $0) }
        await MainActor.run { entries = Array(parsed) }
    }

    private var auditFolderURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdmeter/audit", isDirectory: true)
    }
}

/// One row in the JSONL audit log, decoded lazily for display.
struct AuditEntry {
    let raw: String
    let at: String
    let kind: String
    let sessionId: String
    let sourcePeer: String
    let summary: String

    init?(raw: String) {
        self.raw = raw
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        self.at = (dict["at"] as? String) ?? "—"
        self.kind = (dict["kind"] as? String) ?? "?"
        self.sessionId = (dict["sessionId"] as? String) ?? "?"
        self.sourcePeer = (dict["sourcePeer"] as? String) ?? "?"

        switch self.kind {
        case "send":
            let bytes = (dict["textBytes"] as? Int) ?? 0
            let hash = (dict["textHash"] as? String) ?? ""
            let head = String(hash.prefix(12))
            if let text = dict["text"] as? String {
                self.summary = "\(bytes)B  \(text.prefix(120))"
            } else {
                self.summary = "\(bytes)B  hash=\(head)"
            }
        case "swap":
            let from = (dict["oldModel"] as? String) ?? "?"
            let to = (dict["newModel"] as? String) ?? "?"
            let eff = (dict["effort"] as? String) ?? "?"
            self.summary = "\(from) → \(to)  effort=\(eff)"
        case "autopilot":
            let enabled = (dict["enabled"] as? Bool) ?? false
            let repo = (dict["repoKey"] as? String) ?? "?"
            self.summary = "\(enabled ? "ON " : "OFF") repo=\(repo)"
        default:
            self.summary = raw
        }
    }
}

private struct AuditEntryRow: View {
    let entry: AuditEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.at)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 180, alignment: .leading)
                Text(entry.summary)
                    .font(.callout)
                    .lineLimit(expanded ? nil : 1)
                    .truncationMode(.tail)
                Spacer()
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                Text(entry.sessionId.prefix(8) + "…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(entry.sourcePeer)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if expanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(entry.raw)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
