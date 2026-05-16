import SwiftUI
import ClawdmeterShared

/// Sessions v2 T17. Reader UI for the JSONL audit log under
/// `~/.clawdmeter/audit/`. Shows the most recent 200 entries per stream
/// (sends / swaps / autopilot) with filter + search. Mirrors dmux's logs
/// popup pattern.
///
/// T18 (Wire Inspector) lives inside the same Diagnostics tab — toggle
/// the segmented control at the top to switch between Audit Log and Wire
/// Inspector. The inspector is off by default; turning it on starts
/// recording HTTP request/response bodies into a rolling buffer.
struct DiagnosticsSettingsView: View {
    enum Surface: String, CaseIterable, Identifiable {
        case auditLog = "Audit Log"
        case wireInspector = "Wire Inspector"
        var id: String { rawValue }
    }
    @State private var surface: Surface = .auditLog
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
            surfacePicker
            Divider()
            Group {
                switch surface {
                case .auditLog:
                    auditLogSurface
                case .wireInspector:
                    WireInspectorPane()
                }
            }
        }
        .padding(.vertical, 12)
        .frame(minWidth: 560, minHeight: 400)
        .task(id: refreshTick) { await reload() }
        .task(id: selectedKind) { await reload() }
    }

    private var surfacePicker: some View {
        Picker("Surface", selection: $surface) {
            ForEach(Surface.allCases) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var auditLogSurface: some View {
        header
        Divider()
        if filteredEntries.isEmpty {
            emptyState
        } else {
            entryList
        }
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

/// T18. Live tail of the WireInspector rolling buffer. Off by default;
/// toggle the switch to start recording. Polls every second when visible.
struct WireInspectorPane: View {
    @State private var entries: [WireInspector.Entry] = []
    @State private var enabled: Bool = false
    @State private var query: String = ""
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !enabled && entries.isEmpty {
                offState
            } else if filtered.isEmpty {
                Spacer()
                Text("Waiting for traffic…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { entry in
                            WireInspectorRow(entry: entry)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
            }
        }
        .task {
            enabled = await WireInspector.shared.isEnabled()
            pollTask = Task { await pollLoop() }
        }
        .onDisappear { pollTask?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Toggle(isOn: $enabled) {
                    Text("Record HTTP/WS payloads")
                }
                .toggleStyle(.switch)
                .onChange(of: enabled) { _, on in
                    Task { await WireInspector.shared.setEnabled(on) }
                }
                Spacer()
                Button("Clear") {
                    Task { await WireInspector.shared.clear(); await refresh() }
                }
                .disabled(entries.isEmpty)
            }
            TextField("Filter path or peer", text: $query)
                .textFieldStyle(.roundedBorder)
            Text("Capped at 500 entries (~5MB). Bodies under 16KB sniff JSON; larger payloads stub as `NB <content-type>`.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var offState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Inspector is off")
                .foregroundStyle(.secondary)
            Text("Toggle the switch to start recording.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var filtered: [WireInspector.Entry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return entries.reversed() }
        return entries.reversed().filter {
            $0.path.lowercased().contains(q) || $0.peer.lowercased().contains(q)
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    @MainActor
    private func refresh() async {
        let latest = await WireInspector.shared.entries(limit: 500)
        entries = latest
    }
}

private struct WireInspectorRow: View {
    let entry: WireInspector.Entry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.direction.rawValue)
                    .font(.caption.monospaced())
                    .foregroundStyle(entry.direction == .incoming ? Color.green : Color.blue)
                if let method = entry.method {
                    Text(method)
                        .font(.caption.monospaced().bold())
                }
                if let status = entry.status {
                    Text("\(status)")
                        .font(.caption.monospaced())
                        .foregroundStyle(status >= 400 ? .red : .secondary)
                }
                Text(entry.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(entry.at.formatted(.dateTime.hour().minute().second()))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(entry.bodyPreview.isEmpty)
            }
            if expanded && !entry.bodyPreview.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(entry.bodyPreview)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
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
