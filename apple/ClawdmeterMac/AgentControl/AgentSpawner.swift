import Foundation
import ClawdmeterShared

/// Builds the child-process argv that runs inside a tmux pane for a given
/// (agent, cwd, options) tuple.
///
/// Per E4: returns argv arrays, NEVER `cd && exec` shell strings. The
/// caller (`TmuxControlClient.newWindow`) passes the cwd separately via
/// tmux's `-c` flag.
///
/// Sessions v2 changes (T1 + T2 + T3 + Phase 0):
/// - Uses `ShellRunner.locateBinary` instead of hardcoded user-specific paths.
/// - Claude effort: `--effort <low|medium|high|xhigh|max>` (verified via
///   `claude --help` 2.1.141).
/// - Codex effort: `-c model_reasoning_effort="<value>"` (verified via
///   `codex --help` 2026-05). Codex does NOT have a `--reasoning-effort` flag.
public enum AgentSpawner {

    /// Build argv for spawning Claude with the given options.
    /// Returns nil if the `claude` binary cannot be located — caller surfaces
    /// the preflight error.
    public static func claudeArgv(
        model: String? = nil,
        planMode: Bool = false,
        effort: ReasoningEffort? = nil,
        autopilot: Bool = false,
        resumeSessionId: String? = nil,
        extraArgs: [String] = []
    ) -> [String]? {
        guard let claude = ShellRunner.locateBinary("claude") else { return nil }
        var argv = [claude]
        if let resumeSessionId, !resumeSessionId.isEmpty {
            argv += ["--resume", resumeSessionId]
        }
        if let model, !model.isEmpty {
            argv += ["--model", model]
        }
        if planMode {
            argv += ["--permission-mode", "plan"]
        } else if autopilot {
            // E7 guardrails wrap this with audit + timeout + per-repo trust.
            argv += ["--dangerously-skip-permissions"]
        }
        if let effort {
            argv += ["--effort", effort.claudeFlagValue]
        }
        argv.append(contentsOf: extraArgs)
        return argv
    }

    /// Build argv for spawning Codex with the given options. Returns nil if
    /// the `codex` binary cannot be located.
    ///
    /// `planMode` maps to Codex's `--sandbox read-only` (verified via
    /// `codex --help` 2026-05). Read-only sandbox prevents Codex from
    /// writing or executing mutating commands — the agent reads + plans,
    /// then the user reviews and switches to `workspace-write` to
    /// execute. Same UX shape as Claude's `--permission-mode plan`,
    /// just a different transport.
    public static func codexArgv(
        model: String? = nil,
        planMode: Bool = false,
        effort: ReasoningEffort? = nil,
        autopilot: Bool = false,
        resumeSessionId: String? = nil,
        extraArgs: [String] = []
    ) -> [String]? {
        guard let codex = ShellRunner.locateBinary("codex") else { return nil }
        var argv = [codex]
        if let resumeSessionId, !resumeSessionId.isEmpty {
            argv += ["resume", resumeSessionId]
        }
        if let model, !model.isEmpty {
            argv += ["--model", model]
        }
        // Effort is a config override on Codex (no direct flag). TOML literal
        // syntax: model_reasoning_effort="medium" with quoted string value.
        if let effort {
            argv += ["-c", "model_reasoning_effort=\"\(effort.codexConfigValue)\""]
        }
        if planMode {
            // Read-only sandbox = Codex's plan mode. The agent can read
            // and propose, but anything that would mutate the workspace
            // (writes, network calls, non-trivial shell) is blocked.
            // approve-plan flips this to workspace-write on user OK.
            argv += ["-s", "read-only"]
        } else if autopilot {
            argv += ["--dangerously-bypass-approvals-and-sandbox"]
        }
        argv.append(contentsOf: extraArgs)
        return argv
    }

    /// Build argv for a `NewSessionRequest`. Returns an empty array if the
    /// required binary is missing — caller checks and surfaces the error.
    public static func argv(for request: NewSessionRequest, autopilot: Bool = false) -> [String] {
        switch request.agent {
        case .claude:
            return claudeArgv(
                model: request.model,
                planMode: request.planMode,
                effort: request.effort,
                autopilot: autopilot
            ) ?? []
        case .codex:
            return codexArgv(
                model: request.model,
                planMode: request.planMode,
                effort: request.effort,
                autopilot: autopilot
            ) ?? []
        }
    }

    /// Build argv for re-spawning an existing session with new config
    /// (model/effort/mode/plan swap). Uses `--resume` for Claude and
    /// `codex resume <id>` for Codex to preserve chat history (D12).
    /// The caller still needs the D13 overlay flow to handle the visual gap.
    public static func respawnArgv(
        agent: AgentKind,
        resumeSessionId: String,
        model: String?,
        planMode: Bool,
        effort: ReasoningEffort?,
        autopilot: Bool
    ) -> [String] {
        switch agent {
        case .claude:
            return claudeArgv(
                model: model,
                planMode: planMode,
                effort: effort,
                autopilot: autopilot,
                resumeSessionId: resumeSessionId
            ) ?? []
        case .codex:
            return codexArgv(
                model: model,
                planMode: planMode,
                effort: effort,
                autopilot: autopilot,
                resumeSessionId: resumeSessionId
            ) ?? []
        }
    }

    /// Best-effort: locate the agent binaries at app launch and verify
    /// they exist. Returns the user-visible reason if either is missing.
    public static func preflight() -> String? {
        var missing: [String] = []
        if ShellRunner.locateBinary("claude") == nil {
            missing.append("claude")
        }
        if ShellRunner.locateBinary("codex") == nil {
            missing.append("codex")
        }
        if missing.isEmpty { return nil }
        return "Agent CLI not found on PATH: \(missing.joined(separator: ", ")). Configure in Settings → Diagnostics."
    }

    /// Agent-specific preflight for starting a single selected runtime.
    public static func preflight(agent: AgentKind) -> String? {
        let binary = agent.rawValue
        if ShellRunner.locateBinary(binary) == nil {
            return "Agent CLI not found on PATH: \(binary). Configure in Settings → Diagnostics."
        }
        return nil
    }
}
