import Foundation
import OSLog

private let pluginLogger = Logger(subsystem: "com.clawdmeter.mac", category: "PluginRegistry")

/// G18 plugin pass-through. Surfaces what the underlying Claude / Codex
/// CLIs have configured so the user can see what extra capabilities the
/// agents bring in. Read-only in v1 — enabling/disabling plugins is the
/// upstream CLI's job, we just inventory.
public struct PluginInfo: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let kind: Kind
    public let source: String
    public enum Kind: String, Sendable {
        case codexMCP    // mcp_servers.* section in ~/.codex/config.toml
        case claudeMCP   // mcpServers.* in ~/.claude/settings.json
        case claudePlugin // enabledPlugins.* in ~/.claude/settings.json
    }
}

public enum PluginRegistry {

    public static func discover() -> [PluginInfo] {
        var out: [PluginInfo] = []
        out.append(contentsOf: scanCodexConfig())
        out.append(contentsOf: scanClaudeSettings())
        return out
    }

    private static func scanCodexConfig() -> [PluginInfo] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        // Lightweight TOML walk: collect top-level mcp_servers.<name> headers
        // and ignore deeper sub-sections (e.g. .tools, .env, .http_headers).
        var seen: Set<String> = []
        var found: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[mcp_servers."), trimmed.hasSuffix("]") else { continue }
            let inner = String(trimmed.dropFirst("[mcp_servers.".count).dropLast(1))
            // Skip sub-tables.
            let name = inner.split(separator: ".").first.map(String.init) ?? inner
            if !seen.contains(name) {
                seen.insert(name)
                found.append(name)
            }
        }
        return found.map {
            PluginInfo(name: $0, kind: .codexMCP, source: "~/.codex/config.toml")
        }
    }

    private static func scanClaudeSettings() -> [PluginInfo] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }
        var out: [PluginInfo] = []
        if let plugins = json["enabledPlugins"] as? [String: Any] {
            for (name, enabled) in plugins where (enabled as? Bool) == true {
                out.append(PluginInfo(
                    name: name, kind: .claudePlugin,
                    source: "~/.claude/settings.json"
                ))
            }
        }
        if let mcps = json["mcpServers"] as? [String: Any] {
            for name in mcps.keys {
                out.append(PluginInfo(
                    name: name, kind: .claudeMCP,
                    source: "~/.claude/settings.json"
                ))
            }
        }
        return out
    }
}
