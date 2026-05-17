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

    enum Source: Hashable {
        case claudeGlobal       // ~/.claude/skills/<name>
        case claudeProject      // <repo>/.claude/skills/<name>
        case codexBuiltin
    }
}

/// Walks installed skills and exposes them as a cached list. Cache TTL
/// 30s + invalidation on `~/.claude/skills/` mtime change (§7 perf inline).
@MainActor
final class SkillCatalog: ObservableObject {

    static let shared = SkillCatalog()

    @Published private(set) var commands: [PaletteCommand] = []
    private var lastLoad: Date = .distantPast
    private var lastGlobalMtime: Date?
    private static let ttl: TimeInterval = 30

    /// Project-local override path. Set by the caller when a repo is in
    /// scope so `<repo>/.claude/skills/` lands in the palette too.
    var projectSkillsRoot: URL? {
        didSet { if oldValue != projectSkillsRoot { lastLoad = .distantPast } }
    }

    func refreshIfStale() {
        let now = Date()
        // mtime check first — cheap; lets us invalidate on user installing a skill.
        let globalRoot = URL(fileURLWithPath: NSString("~/.claude/skills").expandingTildeInPath)
        let mtime = (try? globalRoot.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let mtimeMoved = (mtime != lastGlobalMtime)
        if now.timeIntervalSince(lastLoad) < Self.ttl && !mtimeMoved && !commands.isEmpty {
            return
        }
        lastGlobalMtime = mtime
        lastLoad = now
        commands = enumerate()
    }

    func filter(query: String, forAgent agent: AgentKind) -> [PaletteCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let pool: [PaletteCommand]
        switch agent {
        case .claude: pool = commands.filter { $0.source != .codexBuiltin }
        case .codex:  pool = commands.filter { $0.source == .codexBuiltin }
        }
        if trimmed.isEmpty { return pool }
        return pool.filter {
            $0.id.lowercased().contains(trimmed) || $0.description.lowercased().contains(trimmed)
        }
    }

    // MARK: - Walkers

    private func enumerate() -> [PaletteCommand] {
        var out: [PaletteCommand] = []
        out.append(contentsOf: walkClaudeSkills(root: URL(fileURLWithPath: NSString("~/.claude/skills").expandingTildeInPath), source: .claudeGlobal))
        if let projectSkillsRoot {
            out.append(contentsOf: walkClaudeSkills(root: projectSkillsRoot, source: .claudeProject))
        }
        out.append(contentsOf: codexBuiltins())
        return out.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func walkClaudeSkills(root: URL, source: PaletteCommand.Source) -> [PaletteCommand] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [PaletteCommand] = []
        for entry in entries {
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else { continue }
            guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
            // Parse the YAML frontmatter (extremely permissive).
            guard let (name, description) = parseFrontmatter(content) else {
                paletteLogger.warning("skipped \(skillFile.path, privacy: .public): malformed frontmatter")
                continue
            }
            out.append(PaletteCommand(id: name, label: name, description: description, source: source))
        }
        return out
    }

    private func codexBuiltins() -> [PaletteCommand] {
        [
            PaletteCommand(id: "clear",   label: "clear",   description: "Clear the current conversation context.", source: .codexBuiltin),
            PaletteCommand(id: "compact", label: "compact", description: "Compact the conversation transcript.", source: .codexBuiltin),
            PaletteCommand(id: "model",   label: "model",   description: "Switch the active model for this session.", source: .codexBuiltin),
            PaletteCommand(id: "help",    label: "help",    description: "Show CLI help.", source: .codexBuiltin),
            PaletteCommand(id: "quit",    label: "quit",    description: "Exit the session.", source: .codexBuiltin),
        ]
    }

    /// Pulls `name:` and `description:` from a Claude-Code-style YAML
    /// frontmatter. Tolerant of single-line vs block-scalar descriptions.
    /// Returns nil if the frontmatter is missing or unparseable.
    private func parseFrontmatter(_ content: String) -> (String, String)? {
        guard content.hasPrefix("---\n") else { return nil }
        let body = content.dropFirst(4)
        guard let endRange = body.range(of: "\n---") else { return nil }
        let header = body[body.startIndex..<endRange.lowerBound]
        var name: String?
        var description: String?
        var inDescriptionBlock = false
        var descLines: [String] = []
        for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if inDescriptionBlock {
                // Block-scalar continuation: indented content.
                if raw.hasPrefix("  ") {
                    descLines.append(raw.trimmingCharacters(in: .whitespaces))
                    continue
                }
                inDescriptionBlock = false
                description = descLines.joined(separator: " ")
            }
            if raw.hasPrefix("name:") {
                name = String(raw.dropFirst("name:".count)).trimmingCharacters(in: .whitespaces)
            } else if raw.hasPrefix("description:") {
                let v = String(raw.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
                if v == "|" || v == ">" {
                    inDescriptionBlock = true
                    descLines = []
                } else {
                    description = v
                }
            }
        }
        if inDescriptionBlock {
            description = descLines.joined(separator: " ")
        }
        guard let name, !name.isEmpty else { return nil }
        return (name, description ?? "")
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
            .frame(maxHeight: 280)
        }
        .frame(width: 420)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
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
