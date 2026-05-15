import Foundation
import ClawdmeterShared

/// Builds the child-process argv that runs inside a tmux pane for a given
/// (agent, cwd, options) tuple.
///
/// Per E4: returns argv arrays, NEVER `cd && exec` shell strings. The
/// caller (TmuxControlClient.newWindow) passes the cwd separately via
/// tmux's `-c` flag.
public enum AgentSpawner {

    /// Build argv for spawning Claude with the given options.
    public static func claudeArgv(
        model: String? = nil,
        planMode: Bool = false,
        extraArgs: [String] = []
    ) -> [String] {
        var argv = ["/Users/darshanbathija_1/.local/bin/claude"]
        if let model {
            argv.append("--model")
            argv.append(model)
        }
        if planMode {
            argv.append("--permission-mode")
            argv.append("plan")
        }
        argv.append(contentsOf: extraArgs)
        return argv
    }

    /// Build argv for spawning Codex with the given options.
    public static func codexArgv(
        model: String? = nil,
        extraArgs: [String] = []
    ) -> [String] {
        // Codex config already sets approval_policy=never globally; we
        // don't add per-spawn config here.
        var argv = ["/opt/homebrew/bin/codex"]
        if let model {
            argv.append("--model")
            argv.append(model)
        }
        argv.append(contentsOf: extraArgs)
        return argv
    }

    /// Build argv for a `NewSessionRequest`. The returned argv is what
    /// should run as the tmux window's child command.
    public static func argv(for request: NewSessionRequest) -> [String] {
        switch request.agent {
        case .claude:
            return claudeArgv(model: request.model, planMode: request.planMode)
        case .codex:
            return codexArgv(model: request.model)
        }
    }

    /// Best-effort: locate the agent binaries at app launch and verify
    /// they exist. Returns the user-visible reason if either is missing.
    public static func preflight() -> String? {
        let claude = "/Users/darshanbathija_1/.local/bin/claude"
        let codex = "/opt/homebrew/bin/codex"
        var missing: [String] = []
        if !FileManager.default.isExecutableFile(atPath: claude) {
            missing.append("claude (\(claude))")
        }
        if !FileManager.default.isExecutableFile(atPath: codex) {
            missing.append("codex (\(codex))")
        }
        if missing.isEmpty { return nil }
        return "Agent CLI not found: \(missing.joined(separator: ", "))"
    }
}
