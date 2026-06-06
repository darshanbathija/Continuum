import Foundation
import ClawdmeterShared

/// Builds the child-process argv for providers that still launch an external
/// CLI directly, currently Claude via a per-session PTY.
///
/// Per E4: returns argv arrays, NEVER `cd && exec` shell strings. The
/// caller passes the cwd separately in the runtime launch plan.
///
/// Sessions v2 changes (T1 + T2 + T3 + Phase 0):
/// - Uses `ShellRunner.locateBinary` instead of hardcoded user-specific paths.
/// - Claude effort: `--effort <low|medium|high|xhigh|max>` (verified via
///   `claude --help` 2.1.141).
/// - Codex effort: `-c model_reasoning_effort="<value>"` (verified via
///   `codex --help` 2026-05). Codex does NOT have a `--reasoning-effort` flag.
public enum AgentSpawner {

    /// The child environment for a Claude PTY spawn.
    ///
    /// Without this, a PTY `claude` runs under launchd's thin GUI PATH
    /// (`/usr/bin:/bin:…`) and can't find node/rg/hooks. `extra` carries managed
    /// repo env (only the daemon's repo-env resolver can compute it; callers
    /// without one pass nil). Sanitized LAST so the subscription-billing rail
    /// (no `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN`) always holds.
    public static func claudePtyEnv(extra: [String: String]? = nil) -> [String: String] {
        var base = ProcessInfo.processInfo.environment
        if let extra { for (k, v) in extra { base[k] = v } }
        base = SpawnPathResolver.merged(into: base)
        return ClaudeSpawnEnv.sanitized(base: base)
    }

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
        deepResearch: Bool = false,
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
        // v0.23 (Chat V2): Deep Research overrides effort to max
        // (multi-step search benefits from the deepest reasoning) and
        // forces the WebSearch/WebFetch tool family on. The system-
        // prompt file is shipped in the app bundle's Resources at
        // build time; we load and pass it through `--append-system-prompt`
        // so the agent follows the [research-step]/[research-step-done]
        // contract the V2 UI extracts.
        if deepResearch {
            // Force max effort. Anything else (including a caller-
            // supplied effort) downgrades to max for DR.
            argv += ["--effort", ReasoningEffort.max.claudeFlagValue]
            argv += ["--allowedTools", "WebSearch,WebFetch,Read,Glob,Grep"]
            if let promptText = loadDeepResearchPrompt() {
                argv += ["--append-system-prompt", promptText]
            }
        } else if let effort {
            argv += ["--effort", effort.claudeFlagValue]
        }
        argv.append(contentsOf: extraArgs)
        return argv
    }

    /// Loads the bundled Deep Research system prompt. Lives in the Mac
    /// app's Resources directory; `Bundle.main.url(forResource:withExtension:)`
    /// resolves it at runtime. Returns nil when the resource is missing
    /// — caller falls back to argv without the system prompt addendum
    /// (research mode still works via the tool-allowance flag, just
    /// without the structured trace contract).
    static func loadDeepResearchPrompt() -> String? {
        guard let url = Bundle.main.url(forResource: "deep-research-prompt", withExtension: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }


    /// Build argv for a `NewSessionRequest`. Returns an empty array if the
    /// required binary is missing — caller checks and surfaces the error.
    public static func argv(
        for request: NewSessionRequest,
        workspacePath: String? = nil,
        autopilot: Bool = false
    ) -> [String] {
        switch request.agent {
        case .claude:
            return claudeArgv(
                model: request.model,
                planMode: request.planMode,
                effort: request.effort,
                autopilot: autopilot
            ) ?? []
        case .codex, .gemini, .cursor, .opencode, .grok:
            // Non-Claude providers are managed outside tmux: Codex through
            // app-server, Cursor through ACP, Gemini/Grok through headless
            // harnesses, and OpenCode through its SSE manager.
            return []
        case .unknown:
            // X3: forward-compat unknown agent — no argv builder. Caller
            // sees missingBinary and surfaces a clean error.
            return []
        }
    }

    /// Build argv for a persisted session. Claude is the only remaining
    /// direct-PTY provider; all non-Claude sessions return empty argv so
    /// callers route them through their managed adapters.
    public static func argv(for session: AgentSession, autopilot: Bool = false) -> [String] {
        // Chat sessions always run in plan-mode regardless of stored
        // request flags — that's the safety wedge for v0.8.
        let planMode = session.kind == .chat ? true : (session.status == .planning)
        // Chat sessions never get autopilot. Trust list is per-repo and
        // chat sessions have no repo.
        let chatAutopilot = session.kind == .chat ? false : autopilot

        switch (session.agent, session.kind) {
        case (.claude, _):
            return claudeArgv(
                model: session.model,
                planMode: planMode,
                effort: session.effort,
                autopilot: chatAutopilot,
                // Track A: a session that already captured a CLI session id is a
                // RESUME (idle-teardown / relaunch / crash-degraded) — pass it so
                // `claude --resume` continues the conversation. nil for a fresh
                // session means clean start.
                resumeSessionId: session.claudeSessionId,
                deepResearch: session.deepResearch
            ) ?? []
        case (.codex, _), (.gemini, _), (.cursor, _), (.opencode, _), (.grok, _):
            // Managed transports do not have direct CLI argv. Keep this empty so
            // accidental argv-based spawns fail closed at the caller.
            return []
        case (.unknown, _):
            // X3: forward-compat unknown kind — no argv. Caller surfaces
            // a clean error or routes to a future adapter.
            return []
        }
    }

    /// Build argv for re-spawning an existing Claude direct-PTY session with new
    /// config (model/effort/mode/plan swap). Managed transports rebuild their
    /// adapter instead of respawning via argv.
    public static func respawnArgv(
        agent: AgentKind,
        resumeSessionId: String,
        model: String?,
        planMode: Bool,
        effort: ReasoningEffort?,
        autopilot: Bool,
        acceptEdits: Bool = false,
        workspacePath: String? = nil
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
        case .codex, .gemini, .cursor, .opencode, .grok:
            // v27: non-Claude providers are ACP-harness-driven — respawn /
            // config-swap / approve-plan go through rebuilding the harness
            // bridge, not direct CLI argv. Only Claude respawns via direct PTY.
            return []
        case .unknown:
            // X3: forward-compat unknown agent — no respawn argv builder.
            return []
        }
    }

    /// Locate the Cursor Agent CLI: prefer `cursor-agent`, fall back to `agent`.
    /// Returns nil when neither is on PATH. Used by the cursor preflight +
    /// ChatProviderProbe.
    public static func cursorBinaryPath() -> String? {
        ShellRunner.locateBinary("cursor-agent") ?? ShellRunner.locateBinary("agent")
    }

    /// Argv preflight for starting a direct-PTY runtime.
    public static func preflight(agent: AgentKind) -> String? {
        guard agent == .claude else { return nil }
        let binary = agent.rawValue
        if ShellRunner.locateBinary(binary) == nil {
            return "Agent CLI not found on PATH: \(binary). Configure in Settings → Diagnostics."
        }
        return nil
    }
}
