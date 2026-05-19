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
        acceptEdits: Bool = false,
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
        // Permission mode precedence: plan > bypass (autopilot) > acceptEdits
        // > ask (default). Only one --permission-mode flag may be set.
        if planMode {
            argv += ["--permission-mode", "plan"]
        } else if autopilot {
            // E7 guardrails wrap this with audit + timeout + per-repo trust.
            argv += ["--dangerously-skip-permissions"]
        } else if acceptEdits {
            argv += ["--permission-mode", "acceptEdits"]
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
        acceptEdits: Bool = false,
        resumeSessionId: String? = nil,
        extraArgs: [String] = []
    ) -> [String]? {
        // `acceptEdits` is a no-op on Codex — `workspace-write` is the
        // default sandbox and already auto-accepts in-workspace writes
        // while still gating Bash + network. Kept in the signature so
        // callers don't need to branch.
        _ = acceptEdits
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

    /// Build argv for spawning Gemini with the given options. Returns nil if
    /// the `gemini` binary cannot be located.
    ///
    /// CLI flags verified against `gemini --help` (CLI 0.42.0, 2026-05):
    ///   -m / --model            model selection (accepts `pro-high`/`pro`/`flash` aliases)
    ///   --approval-mode plan    read-only mode; agent reads + plans, no mutations
    ///   --approval-mode auto_edit  auto-accept file edits (acceptEdits)
    ///   --approval-mode yolo    skip all approval prompts (autopilot)
    ///   -r / --resume <id>      resume a previous session
    ///
    /// `effort` is a no-op for Gemini — the CLI doesn't expose a per-call
    /// effort flag. The user picks a higher-effort model in the catalog
    /// instead (e.g. `gemini-3.1-pro-high` vs `gemini-3.1-pro-low`).
    public static func geminiArgv(
        model: String? = nil,
        planMode: Bool = false,
        effort: ReasoningEffort? = nil,
        autopilot: Bool = false,
        acceptEdits: Bool = false,
        resumeSessionId: String? = nil,
        extraArgs: [String] = []
    ) -> [String]? {
        // Effort is encoded in the model name (per-high / pro-low), not
        // in a separate flag. Kept in signature so callers don't need to branch.
        _ = effort
        guard let gemini = ShellRunner.locateBinary("gemini") else { return nil }
        return GeminiArgvBuilder.argv(
            geminiBinary: gemini,
            model: model,
            planMode: planMode,
            autopilot: autopilot,
            acceptEdits: acceptEdits,
            resumeSessionId: resumeSessionId,
            extraArgs: extraArgs
        )
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
        case .gemini:
            return geminiArgv(
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
        autopilot: Bool,
        acceptEdits: Bool = false
    ) -> [String] {
        switch agent {
        case .claude:
            return claudeArgv(
                model: model,
                planMode: planMode,
                effort: effort,
                autopilot: autopilot,
                acceptEdits: acceptEdits,
                resumeSessionId: resumeSessionId
            ) ?? []
        case .codex:
            return codexArgv(
                model: model,
                planMode: planMode,
                effort: effort,
                autopilot: autopilot,
                acceptEdits: acceptEdits,
                resumeSessionId: resumeSessionId
            ) ?? []
        case .gemini:
            return geminiArgv(
                model: model,
                planMode: planMode,
                effort: effort,
                autopilot: autopilot,
                acceptEdits: acceptEdits,
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
