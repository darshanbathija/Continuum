import SwiftUI
import Foundation
import ClawdmeterShared
import OSLog

private let paletteLogger = Logger(subsystem: "com.clawdmeter.mac", category: "CommandPalette")

/// One entry in the slash-command palette. Could be a user-installed
/// Claude Code skill (walked from `~/.claude/skills/<name>/SKILL.md`),
/// a Codex built-in, or a project-local skill from `<repo>/.claude/skills/`.
struct PaletteCommand: Identifiable, Hashable {
    let id: String          // skill name (e.g. "plan-ceo-review")
    let label: String       // user-visible name (often matches id)
    let description: String
    let source: Source
    /// Absolute path to `SKILL.md` when the skill is file-backed.
    let filePath: String?

    enum Source: Hashable {
        case claudeGlobal       // ~/.claude/skills/<name>
        case claudeProject      // <repo>/.claude/skills/<name>
        case gstack             // ~/.agents/skills/gstack/<name>
        case customPlugin(id: String)
        case codexBuiltin
    }
}

/// One row inside a skill directory (e.g. `SKILL.md`, `references/`).
struct SkillDirectoryEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
}

/// Loaded detail for the Settings → Providers → Skills inspector.
struct SkillDetail: Equatable {
    let command: PaletteCommand
    let bodyMarkdown: String
    let lastModified: Date?
    let children: [SkillDirectoryEntry]
}

/// Walks installed skills and exposes them as a cached list. Cache TTL
/// 30s + invalidation on `~/.claude/skills/` mtime change (§7 perf inline).
///
/// The walk + frontmatter parse runs on a background task so opening the
/// palette never stalls the main thread, even on a cold cache miss
/// (127 file reads on dev machines — review §7 finding 2026-05-18).
@MainActor
final class SkillCatalog: ObservableObject {

    static let shared = SkillCatalog()

    @Published private(set) var commands: [PaletteCommand] = []
    private var lastLoad: Date = .distantPast
    private var lastGlobalMtime: Date?
    private var refreshTask: Task<Void, Never>?
    private static let ttl: TimeInterval = 30

    /// Project-local override path. Set by the caller when a repo is in
    /// scope so `<repo>/.claude/skills/` lands in the palette too.
    var projectSkillsRoot: URL? {
        didSet { if oldValue != projectSkillsRoot { lastLoad = .distantPast } }
    }

    /// Trigger an async refresh if the cache is stale. Returns immediately;
    /// `commands` keeps serving the previous value (or empty on first run)
    /// while the background task scans + parses. The Published commands
    /// update on completion. Callers that need fresh data on first paint
    /// should await `refreshIfStaleAsync()`.
    func refreshIfStale() {
        guard shouldRefresh() else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    /// Awaitable variant — useful for tests and for callers that need to
    /// know when the catalog is fresh.
    func refreshIfStaleAsync() async {
        guard shouldRefresh() else { return }
        await performRefresh()
    }

    /// Force the next refresh to rescan skill directories.
    func invalidateCache() {
        lastLoad = .distantPast
    }

    private func shouldRefresh() -> Bool {
        let now = Date()
        let globalRoot = URL(fileURLWithPath: NSString("~/.claude/skills").expandingTildeInPath)
        let mtime = (try? globalRoot.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let mtimeMoved = (mtime != lastGlobalMtime)
        if now.timeIntervalSince(lastLoad) < Self.ttl && !mtimeMoved && !commands.isEmpty {
            return false
        }
        lastGlobalMtime = mtime
        lastLoad = now
        return true
    }

    private func performRefresh() async {
        let projectRoot = projectSkillsRoot
        // The heavy work — 127 file reads + frontmatter parse — moves off
        // the main actor here. `enumerate` and helpers are nonisolated.
        let customRoots = SkillPluginStore.customPluginRoots()
        let fresh = await Task.detached(priority: .utility) {
            Self.enumerateNonisolated(projectSkillsRoot: projectRoot, customPluginRoots: customRoots)
        }.value
        // Hop back to main to publish.
        commands = fresh
    }

    func filter(query: String, forAgent agent: AgentKind) -> [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let pool: [PaletteCommand]
        switch agent {
        case .claude: pool = commands.filter { $0.source != .codexBuiltin }
        case .codex:  pool = commands.filter { $0.source == .codexBuiltin }
        case .gemini:
            // No Gemini-specific palette yet — reuse Codex's built-in
            // slash commands so the chip shows something useful.
            pool = commands.filter { $0.source == .codexBuiltin }
        case .opencode:
            // PR #29: OpenCode has its own slash commands (`/init`,
            // `/compact`, `/share`, etc.) but the discovery wire isn't
            // plumbed yet — surface no palette so the chip stays
            // collapsed rather than showing inapplicable Codex hints.
            pool = []
        case .cursor:
            // Cursor slash-command discovery is not exposed by the CLI probe
            // yet, so keep the palette empty instead of showing Codex hints.
            pool = []
        case .grok:
            // No grok slash-command palette wired yet — keep it collapsed.
            pool = []
        case .unknown:
            // X3: forward-compat unknown agent — no palette plumbed.
            pool = []
        }
        // gstack installs the same skills into both ~/.claude/skills and
        // ~/.agents/skills/gstack, so a name like "review" surfaces twice in
        // the Claude pool. Collapse by id (Claude copy wins) so the list
        // doesn't double-list or collide the ForEach `id: \.element.id` keys.
        let deduped = Self.dedupedByID(pool)
        if trimmed.isEmpty { return deduped }
        return deduped.filter {
            $0.id.lowercased().contains(trimmed) || $0.description.lowercased().contains(trimmed)
        }
    }

    /// Source preference when two commands share an id. Lower wins: a
    /// user's own Claude skill outranks the gstack/plugin copy of the same
    /// name.
    nonisolated static func sourcePriority(_ source: PaletteCommand.Source) -> Int {
        switch source {
        case .claudeProject: return 0
        case .claudeGlobal:  return 1
        case .gstack:        return 2
        case .customPlugin:  return 3
        case .codexBuiltin:  return 4
        }
    }

    /// Collapse same-id commands to one entry, keeping the highest-priority
    /// source. Preserves the input's (label) ordering.
    nonisolated static func dedupedByID(_ commands: [PaletteCommand]) -> [PaletteCommand] {
        var bestPriority: [String: Int] = [:]
        for command in commands {
            let priority = sourcePriority(command.source)
            if let existing = bestPriority[command.id], existing <= priority { continue }
            bestPriority[command.id] = priority
        }
        var emitted = Set<String>()
        var out: [PaletteCommand] = []
        for command in commands {
            guard bestPriority[command.id] == sourcePriority(command.source) else { continue }
            if emitted.insert(command.id).inserted { out.append(command) }
        }
        return out
    }

    // MARK: - Walkers (all `nonisolated static` so `Task.detached` can run them off main)

    nonisolated static func enumerateNonisolated(
        projectSkillsRoot: URL?,
        customPluginRoots: [(id: String, root: URL)] = []
    ) -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        // gstack installs its skills into ~/.claude/skills (so the CLI can
        // actually run them) AND keeps a repo checkout at ~/.agents/skills/gstack.
        // Use the checkout only as a *roster* of which names are gstack-managed,
        // then emit each skill once from ~/.claude/skills — tagging gstack ones
        // .gstack and the user's own .claudeGlobal. Walking both roots for
        // emission listed every gstack skill twice (palette dup-id + double rows).
        let gstackRoster = gstackSkillNames()
        out.append(contentsOf: walkClaudeSkills(
            root: URL(fileURLWithPath: NSString("~/.claude/skills").expandingTildeInPath),
            source: .claudeGlobal,
            reclassifyGstack: gstackRoster
        ))
        if let projectSkillsRoot {
            out.append(contentsOf: walkClaudeSkills(root: projectSkillsRoot, source: .claudeProject))
        }
        for plugin in customPluginRoots {
            out.append(contentsOf: walkPluginSkills(root: plugin.root, source: .customPlugin(id: plugin.id)))
        }
        out.append(contentsOf: codexBuiltins())
        return out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Names of skills in the gstack repo checkout, used to tag their copies
    /// under ~/.claude/skills as `.gstack` rather than `.claudeGlobal`. Empty
    /// when gstack isn't installed.
    nonisolated static func gstackSkillNames() -> Set<String> {
        let root = URL(fileURLWithPath: NSString("~/.agents/skills/gstack").expandingTildeInPath)
        return Set(walkPluginSkills(root: root, source: .gstack).map(\.id))
    }

    /// Load the rendered body + directory children for a file-backed skill.
    nonisolated static func loadDetail(for command: PaletteCommand) -> SkillDetail? {
        guard let filePath = command.filePath else {
            guard command.source == .codexBuiltin else { return nil }
            return SkillDetail(
                command: command,
                bodyMarkdown: command.description,
                lastModified: nil,
                children: []
            )
        }
        guard let content = try? String(contentsOf: URL(fileURLWithPath: filePath), encoding: .utf8) else {
            return nil
        }
        let body = stripFrontmatter(from: content)
        let skillDir = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        let mtime = (try? skillDir
            .appendingPathComponent("SKILL.md")
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate)
        let children = listSkillDirectory(skillDir)
        return SkillDetail(
            command: command,
            bodyMarkdown: body,
            lastModified: mtime,
            children: children
        )
    }

    nonisolated private static func stripFrontmatter(from content: String) -> String {
        guard content.hasPrefix("---\n") else { return content }
        let body = content.dropFirst(4)
        guard let endRange = body.range(of: "\n---") else { return content }
        let remainder = body[endRange.upperBound...]
        if remainder.hasPrefix("\n") {
            return String(remainder.dropFirst())
        }
        return String(remainder)
    }

    nonisolated private static func listSkillDirectory(_ root: URL) -> [SkillDirectoryEntry] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return SkillDirectoryEntry(id: url.path, name: url.lastPathComponent, isDirectory: isDir)
            }
    }

    /// Whether a plugin root contains at least one discoverable skill.
    nonisolated static func pluginRootContainsSkills(_ path: String) -> Bool {
        !walkPluginSkills(
            root: URL(fileURLWithPath: path, isDirectory: true),
            source: .customPlugin(id: "probe")
        ).isEmpty
    }

    /// Plugin repos may lay out skills one or two directories deep.
    nonisolated private static func walkPluginSkills(root: URL, source: PaletteCommand.Source) -> [PaletteCommand] {
        var out = walkClaudeSkills(root: root, source: source)
        if !out.isEmpty { return out }

        let rootSkill = root.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: rootSkill.path),
           let content = try? String(contentsOf: rootSkill, encoding: .utf8),
           let parsed = SkillFrontmatter.parse(content) {
            return [PaletteCommand(
                id: parsed.name,
                label: parsed.name,
                description: parsed.description,
                source: source,
                filePath: rootSkill.path
            )]
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            out.append(contentsOf: walkClaudeSkills(root: entry, source: source))
        }
        return out
    }

    nonisolated private static func walkClaudeSkills(
        root: URL,
        source: PaletteCommand.Source,
        reclassifyGstack roster: Set<String> = []
    ) -> [PaletteCommand] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [PaletteCommand] = []
        for entry in entries {
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else { continue }
            guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
            guard let parsed = SkillFrontmatter.parse(content) else {
                paletteLogger.warning("skipped \(skillFile.path, privacy: .public): malformed frontmatter")
                continue
            }
            // A ~/.claude/skills entry whose name is in the gstack roster is a
            // gstack-managed copy — surface it under the G stack group, not Claude.
            let effectiveSource: PaletteCommand.Source =
                roster.contains(parsed.name) ? .gstack : source
            out.append(PaletteCommand(
                id: parsed.name,
                label: parsed.name,
                description: parsed.description,
                source: effectiveSource,
                filePath: skillFile.path
            ))
        }
        return out
    }

    nonisolated private static func codexBuiltins() -> [PaletteCommand] {
        [
            PaletteCommand(id: "clear",   label: "clear",   description: "Clear the current conversation context.", source: .codexBuiltin, filePath: nil),
            PaletteCommand(id: "compact", label: "compact", description: "Compact the conversation transcript.", source: .codexBuiltin, filePath: nil),
            PaletteCommand(id: "model",   label: "model",   description: "Switch the active model for this session.", source: .codexBuiltin, filePath: nil),
            PaletteCommand(id: "help",    label: "help",    description: "Show CLI help.", source: .codexBuiltin, filePath: nil),
            PaletteCommand(id: "quit",    label: "quit",    description: "Exit the session.", source: .codexBuiltin, filePath: nil),
        ]
    }

    /// Re-exported for callers that still reference the old name. New
    /// code should call `SkillFrontmatter.parse(_:)` directly.
    nonisolated static func parseFrontmatter(_ content: String) -> (String, String)? {
        guard let r = SkillFrontmatter.parse(content) else { return nil }
        return (r.name, r.description)
    }

}

enum SkillShareWriter {
    enum Error: Swift.Error, LocalizedError {
        case noSourceFile

        var errorDescription: String? {
            switch self {
            case .noSourceFile: return "This skill has no file to download."
            }
        }
    }

    static func sanitizedFilename(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return safe.isEmpty ? "skill" : safe
    }

    static func export(detail: SkillDetail, outputRoot: URL? = nil) throws -> URL {
        guard let sourcePath = detail.command.filePath else {
            throw Error.noSourceFile
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let root = outputRoot ?? downloads
        let filename = "\(sanitizedFilename(for: detail.command.label)).md"
        let destURL = uniqueDestinationURL(
            root.appendingPathComponent(filename)
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: sourcePath),
            to: destURL
        )
        return destURL
    }

    private static func uniqueDestinationURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        var counter = 1
        while true {
            let candidate = directory.appendingPathComponent("\(base) (\(counter)).md")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }
}

/// Anchored popover above the composer when the user types '/' at the
/// start of the input (or just '/' on a new line). Up/Down/Enter/Esc
/// nav; substring fuzzy filter (11A locked).
struct CommandPaletteView: View {
    @ObservedObject var catalog: SkillCatalog
    let agent: AgentKind
    @Binding var query: String
    let onSelect: (PaletteCommand) -> Void
    let onDismiss: () -> Void

    @State private var selectedIndex: Int = 0

    var filtered: [PaletteCommand] {
        catalog.filter(query: query, forAgent: agent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "command")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Slash commands")
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { (idx, cmd) in
                        row(cmd, isSelected: idx == selectedIndex)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(cmd) }
                    }
                }
            }
            // Sized to match the model-family selector popover (520×440): the
            // list grows to ~400 (≈440 total with the header) when showing the
            // full skill catalog, then shrinks naturally as the query filters.
            .frame(maxHeight: 400)
        }
        .frame(width: 520)
        .background(ContinuumTokens.surface3, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            catalog.refreshIfStale()
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .background(KeyMonitor(
            up: { selectedIndex = max(0, selectedIndex - 1) },
            down: { selectedIndex = min(max(0, filtered.count - 1), selectedIndex + 1) },
            enter: { if let pick = filtered[safe: selectedIndex] { onSelect(pick) } },
            escape: onDismiss
        ))
    }

    @ViewBuilder
    private func row(_ cmd: PaletteCommand, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("/\(cmd.id)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
            Text(cmd.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            badge(for: cmd.source)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func badge(for source: PaletteCommand.Source) -> some View {
        switch source {
        case .claudeGlobal:
            tag("Claude", color: .orange)
        case .claudeProject:
            tag("Project", color: .blue)
        case .gstack:
            tag("G stack", color: .green)
        case .customPlugin:
            tag("Plugin", color: .teal)
        case .codexBuiltin:
            tag("Codex", color: .purple)
        }
    }

    private func tag(_ s: String, color: Color) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(color)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

/// Hidden NSViewRepresentable that captures arrow / enter / escape inside
/// the palette popover. SwiftUI's `onKeyPress` only fires when the focus
/// owner is the view itself, which is the TextField underneath; this lets
/// the palette steal those keys without focus.
struct KeyMonitor: NSViewRepresentable {
    let up: () -> Void
    let down: () -> Void
    let enter: () -> Void
    let escape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 126: up(); return nil       // up arrow
            case 125: down(); return nil     // down arrow
            case 36, 76: enter(); return nil // return + numpad return
            case 53: escape(); return nil    // escape
            default: return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
        coordinator.monitor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
    }
}
