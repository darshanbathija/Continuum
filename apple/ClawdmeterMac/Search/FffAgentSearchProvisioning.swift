import Foundation
import ClawdmeterShared

/// Bundles Continuum-managed FFF search for agent runtimes:
///   - Claude Code: `--mcp-config` pointing at bundled `fff-mcp`
///   - Codex: `[mcp_servers.fff]` merged into the active `config.toml`
///   - OpenCode: `OPENCODE_CONFIG` + `opencode-fff-search` plugin
enum FffAgentSearchProvisioning {

    static let mcpServerName = "fff"
    static let bundledMCPBinaryName = "fff-mcp"

    private static let claudeConfigFileName = "claude-fff-mcp.json"
    private static let codexSectionHeader = "[mcp_servers.\(mcpServerName)]"

    // MARK: - Public entry points

    /// Best-effort provisioning for all agent-side FFF integrations. Safe to
    /// call repeatedly from app boot and spawn paths.
    static func ensureProvisioned() {
        _ = writeClaudeMCPConfigIfNeeded()
        ensureDefaultCodexMCPConfig()
    }

    /// Path for Claude `--mcp-config` when the bundled MCP binary is present.
    static func claudeMCPConfigArgument() -> String? {
        guard bundledMCPBinaryPath() != nil else { return nil }
        return writeClaudeMCPConfigIfNeeded()?.path
    }

    /// Environment overrides for `opencode serve` to load the bundled plugin.
    static func openCodeEnvironmentOverrides() -> [String: String] {
        guard let configURL = bundledOpenCodeConfigURL(),
              FileManager.default.fileExists(atPath: configURL.path) else {
            return [:]
        }
        let configDir = configURL.deletingLastPathComponent()
        return [
            "OPENCODE_CONFIG": configURL.path,
            "OPENCODE_CONFIG_DIR": configDir.path,
        ]
    }

    /// Merge the bundled FFF MCP server into the Codex config home that will
    /// be used by the next `codex app-server` spawn.
    static func ensureCodexMCPConfig(in childEnv: [String: String]) {
        guard let command = bundledMCPBinaryPath() else { return }
        let codexHome = codexHome(from: childEnv)
        mergeCodexMCPSection(into: codexHome.appendingPathComponent("config.toml"), command: command)
    }

    // MARK: - Bundled asset resolution

    static func bundledMCPBinaryPath() -> String? {
        if let override = UserDefaults.standard.string(forKey: "clawdmeter.libraries.fff-mcp"),
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL
                .appendingPathComponent("Vendor", isDirectory: true)
                .appendingPathComponent("fff", isDirectory: true)
                .appendingPathComponent(bundledMCPBinaryName, isDirectory: false)
                .path
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }

        #if DEBUG
        if let envOverride = ProcessInfo.processInfo.environment["CLAWDMETER_FFF_MCP"],
           !envOverride.isEmpty,
           FileManager.default.isExecutableFile(atPath: envOverride) {
            return envOverride
        }
        #endif

        return nil
    }

    static func bundledOpenCodeConfigURL() -> URL? {
        if let override = UserDefaults.standard.string(forKey: "clawdmeter.opencode.fffConfig"),
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL
                .appendingPathComponent("Vendor", isDirectory: true)
                .appendingPathComponent("opencode-fff", isDirectory: true)
                .appendingPathComponent("config", isDirectory: true)
                .appendingPathComponent("opencode.json", isDirectory: false)
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        #if DEBUG
        if let envOverride = ProcessInfo.processInfo.environment["CLAWDMETER_OPENCODE_FFF_CONFIG"],
           !envOverride.isEmpty {
            let url = URL(fileURLWithPath: envOverride)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        #endif

        return nil
    }

    // MARK: - Claude MCP config

    @discardableResult
    static func writeClaudeMCPConfigIfNeeded() -> URL? {
        guard let command = bundledMCPBinaryPath() else { return nil }
        let url = managedSupportDirectory()
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent(claudeConfigFileName, isDirectory: false)
        let payload: [String: Any] = [
            "mcpServers": [
                mcpServerName: [
                    "type": "stdio",
                    "command": command,
                    "args": [] as [String],
                ],
            ],
        ]
        do {
            try writeJSON(payload, to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Codex MCP config

    private static func ensureDefaultCodexMCPConfig() {
        guard let command = bundledMCPBinaryPath() else { return }
        let defaultHome = ClawdmeterRealHome.url()
            .appendingPathComponent(".codex", isDirectory: true)
        mergeCodexMCPSection(into: defaultHome.appendingPathComponent("config.toml"), command: command)
    }

    static func codexHome(from env: [String: String]) -> URL {
        if let home = env["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return ClawdmeterRealHome.url().appendingPathComponent(".codex", isDirectory: true)
    }

    static func mergeCodexMCPSection(into configURL: URL, command: String) {
        let fm = FileManager.default
        let parent = configURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let escapedCommand = escapeTOMLString(command)

        let desiredBlock = """
        \(codexSectionHeader)
        command = "\(escapedCommand)"

        """

        let existing: String
        if fm.fileExists(atPath: configURL.path),
           let data = try? Data(contentsOf: configURL),
           let text = String(data: data, encoding: .utf8) {
            existing = text
        } else {
            existing = ""
        }

        if existing.contains(codexSectionHeader) {
            if existing.contains("command = \"\(escapedCommand)\"") {
                return
            }
            let updated = replaceCodexMCPSection(in: existing, with: desiredBlock)
            try? updated.write(to: configURL, atomically: true, encoding: .utf8)
            return
        }

        var merged = existing
        if !merged.isEmpty, !merged.hasSuffix("\n") {
            merged += "\n"
        }
        if !merged.isEmpty, !merged.hasSuffix("\n\n") {
            merged += "\n"
        }
        merged += desiredBlock
        try? merged.write(to: configURL, atomically: true, encoding: .utf8)
    }

    static func replaceCodexMCPSection(in text: String, with replacement: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == codexSectionHeader }) else {
            return text + replacement
        }
        var end = start + 1
        while end < lines.count {
            let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                break
            }
            end += 1
        }
        lines.replaceSubrange(start..<end, with: replacement.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func managedSupportDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("Clawdmeter", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func escapeTOMLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
