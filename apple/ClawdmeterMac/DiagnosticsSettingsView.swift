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
    @State private var supportBundleURL: URL?
    @State private var supportBundleError: String?

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
                    createSupportBundle()
                } label: {
                    Label("Support Bundle", systemImage: "shippingbox")
                }
                .buttonStyle(.borderless)
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
            if let supportBundleURL {
                HStack(spacing: 6) {
                    Text("Bundle: \(supportBundleURL.path)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([supportBundleURL])
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let supportBundleError {
                Text(supportBundleError)
                    .font(.caption)
                    .foregroundStyle(.red)
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

    private func createSupportBundle() {
        do {
            let url = try SupportBundleWriter.create(
                auditFolderURL: auditFolderURL,
                wireEntries: entries.map(\.raw)
            )
            supportBundleURL = url
            supportBundleError = nil
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        } catch {
            supportBundleError = error.localizedDescription
        }
    }
}

enum SupportBundleWriter {
    static func create(auditFolderURL: URL, wireEntries: [String], outputRoot: URL? = nil) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let root = (outputRoot ?? downloads).appendingPathComponent("Continuum Support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = root.appendingPathComponent("support-\(Self.stamp())", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let summary = [
            "createdAt=\(ISO8601DateFormatter().string(from: Date()))",
            "bundle=\(Bundle.main.bundleIdentifier ?? "unknown")",
            "version=\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")",
            "build=\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")",
            "shell=\(redact(ProcessInfo.processInfo.environment["SHELL"] ?? "unknown"))",
            "path=\(redact(ProcessInfo.processInfo.environment["PATH"] ?? "unknown"))",
            "auditFolder=\(redact(auditFolderURL.path))"
        ].joined(separator: "\n")
        try summary.write(to: bundle.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)

        try copyRedactedAudit(from: auditFolderURL, to: bundle.appendingPathComponent("audit-redacted", isDirectory: true))
        try redactAuditText(wireEntries.joined(separator: "\n")).write(to: bundle.appendingPathComponent("visible-diagnostics.jsonl"), atomically: true, encoding: .utf8)
        try systemSnapshot().write(to: bundle.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)
        try providerSnapshot().write(to: bundle.appendingPathComponent("provider-binaries.txt"), atomically: true, encoding: .utf8)
        try redact(run("/bin/zsh", ["-lc", "tmux list-sessions 2>&1 || true"])).write(to: bundle.appendingPathComponent("tmux.txt"), atomically: true, encoding: .utf8)
        try redact(run("/bin/zsh", ["-lc", "tailscale status --json 2>&1 || tailscale status 2>&1 || true"])).write(to: bundle.appendingPathComponent("tailscale.txt"), atomically: true, encoding: .utf8)
        try redact(run("/bin/zsh", ["-lc", "lsof -nP -iTCP -sTCP:LISTEN 2>&1 | head -200 || true"])).write(to: bundle.appendingPathComponent("listening-ports.txt"), atomically: true, encoding: .utf8)
        try "App logs are omitted from the default support bundle because they can contain prompt and transcript text. Use visible-diagnostics.jsonl and audit-redacted for sanitized event context.\n"
            .write(to: bundle.appendingPathComponent("app-logs.txt"), atomically: true, encoding: .utf8)
        return bundle
    }

    private static func copyRedactedAudit(from auditFolderURL: URL, to target: URL) throws {
        guard FileManager.default.fileExists(atPath: auditFolderURL.path) else { return }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let rootPath = auditFolderURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: auditFolderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            let filePath = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            let relative = filePath.hasPrefix(rootPath + "/")
                ? String(filePath.dropFirst(rootPath.count + 1))
                : fileURL.lastPathComponent
            let name = (relative.isEmpty ? fileURL.lastPathComponent : relative)
                .replacingOccurrences(of: "/", with: "__")
            try redactAuditText(text).write(to: target.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private static func systemSnapshot() -> String {
        [
            "macOS=\(redact(run("/usr/bin/sw_vers", [])))",
            "uname=\(redact(run("/usr/bin/uname", ["-a"])))",
            "cwd=\(redact(FileManager.default.currentDirectoryPath))",
        ].joined(separator: "\n")
    }

    private static func providerSnapshot() -> String {
        let providers = ["claude", "codex", "gemini", "opencode", "cursor", "tmux", "tailscale", "gh", "git"]
        return providers.map { name in
            let path = redact(run("/bin/zsh", ["-lc", "command -v \(name) 2>/dev/null || true"]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let version = redact(run("/bin/zsh", ["-lc", "\(name) --version 2>&1 | head -5 || true"]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name): \(path.isEmpty ? "missing" : path)\n\(version)"
        }.joined(separator: "\n\n")
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch {
            return error.localizedDescription
        }
    }

    private static func redact(_ value: String) -> String {
        var output = value.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        if let user = ProcessInfo.processInfo.environment["USER"], !user.isEmpty {
            output = output.replacingOccurrences(of: user, with: "<user>")
        }
        let patterns = [
            (#"(?i)"(key|token|access|refresh|secret|password|credential|credentials|api[_-]?key|authorization)"\s*:\s*"[^"]*""#, #""$1":"<redacted>""#),
            (#"(?i)'(key|token|access|refresh|secret|password|credential|credentials|api[_-]?key|authorization)'\s*:\s*'[^']*'"#, #"'$1':'<redacted>'"#),
            (#"(?i)(token|secret|password|credential|credentials|api[_-]?key|authorization|access|refresh)[=: ]+[^\s,]+"#, "$1=<redacted>"),
            (#"sk-[A-Za-z0-9_\-]{12,}"#, "<redacted>"),
            (#"gh[pousr]_[A-Za-z0-9_]{12,}"#, "<redacted>"),
            (#"(?i)[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, "<email>"),
            (#"(?i)\bhttps?://[^/\s"'<>]+"#, "https://<host>"),
            (#"(?i)\b[A-Z0-9][A-Z0-9\-]{1,62}(?:\.[A-Z0-9][A-Z0-9\-]{1,62})+\b"#, "<host>"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<ip>"),
            (#"\b[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4}){2,7}\b"#, "<ip>"),
        ]
        for (pattern, replacement) in patterns {
            output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return output
    }

    static func redactAuditText(_ value: String) -> String {
        var output = redact(value)
        let contentPatterns = [
            (#"(?i)"(text|prompt|body|message|content|goal|planText)"\s*:\s*"(?:\\.|[^"\\])*""#, #""$1":"<redacted-content>""#),
            (#"(?i)'(text|prompt|body|message|content|goal|planText)'\s*:\s*'(?:\\.|[^'\\])*'"#, #"'$1':'<redacted-content>'"#),
        ]
        for (pattern, replacement) in contentPatterns {
            output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return output
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
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
            if let text = dict["text"] as? String {
                self.summary = "\(bytes)B  \(text.prefix(120))"
            } else {
                let head = String(hash.prefix(12))
                self.summary = "\(bytes)B  hash=\(head)"
            }
        case "swap-model", "swap":  // "swap" kept for back-compat with v2.0.1 rows
            let from = (dict["oldModel"] as? String) ?? "?"
            let to = (dict["newModel"] as? String) ?? "?"
            let eff = (dict["effort"] as? String) ?? "(unchanged)"
            self.summary = "model: \(from) → \(to)  effort=\(eff)"
        case "swap-effort":
            let model = (dict["model"] as? String) ?? "?"
            let eff = (dict["effort"] as? String) ?? "?"
            self.summary = "effort=\(eff)  on=\(model)"
        case "swap-mode":
            let mode = (dict["mode"] as? String) ?? "?"
            if let pm = dict["planMode"] as? Bool {
                self.summary = "mode=\(mode)  plan=\(pm ? "on" : "off")"
            } else {
                self.summary = "mode=\(mode)"
            }
        case "plan-approve":
            let agent = (dict["agent"] as? String) ?? "?"
            self.summary = "plan approved → run (agent=\(agent))"
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
                    Text("Record HTTP payloads")
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
            Text("Capped at 500 entries (~5MB). Body text appears only when Privacy → Audit log: include plaintext is on; otherwise the inspector shows shape + byte count only.")
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
