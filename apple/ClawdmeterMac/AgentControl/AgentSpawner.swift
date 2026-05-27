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
        workspacePath: String? = nil,
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
        if let workspacePath, !workspacePath.isEmpty {
            argv += ["-C", workspacePath]
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
    /// instead (e.g. `gemini-3-pro` for deep reasoning vs
    /// `gemini-3.5-flash` for fast iteration).
    public static func geminiArgv(
        model: String? = nil,
        planMode: Bool = false,
        effort: ReasoningEffort? = nil,
        autopilot: Bool = false,
        acceptEdits: Bool = false,
        resumeSessionId: String? = nil,
        trustWorkspace: Bool = false,
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
            trustWorkspace: trustWorkspace,
            extraArgs: extraArgs
        )
    }

    public static func cursorBinaryPath() -> String? {
        if let cursorAgent = ShellRunner.locateBinary("cursor-agent"),
           isCursorAgentBinary(cursorAgent) {
            return cursorAgent
        }
        guard let fallback = ShellRunner.locateBinary("agent"),
              isCursorAgentBinary(fallback) else {
            return nil
        }
        return fallback
    }

    private static func isCursorAgentBinary(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--help"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return false
        }

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            + "\n"
            + String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let lower = output.lowercased()
        return lower.contains("cursor agent")
            && lower.contains("--workspace")
            && lower.contains("--resume")
            && lower.contains("--list-models")
    }

    /// Build argv for Cursor Agent CLI sessions. Cursor differs from the
    /// other providers in two important ways:
    /// - The preferred binary is `cursor-agent`, with `agent` as the fallback.
    /// - The CLI accepts an explicit `--workspace <path>` flag, which we pass
    ///   even though tmux also starts the pane in that cwd. This keeps Cursor's
    ///   own workspace binding aligned with the repo/worktree Clawdmeter picked.
    public static func cursorArgv(
        model: String? = nil,
        planMode: Bool = false,
        effort: ReasoningEffort? = nil,
        autopilot: Bool = false,
        acceptEdits: Bool = false,
        resumeSessionId: String? = nil,
        workspacePath: String? = nil,
        extraArgs: [String] = []
    ) -> [String]? {
        _ = effort
        _ = acceptEdits
        guard let cursor = cursorBinaryPath() else { return nil }
        var argv = [cursor]
        if let workspacePath, !workspacePath.isEmpty {
            argv += ["--workspace", workspacePath]
        }
        if let resumeSessionId, !resumeSessionId.isEmpty {
            argv += ["--resume", resumeSessionId]
        }
        if let model, !CursorModelCatalog.isAutoModel(model) {
            argv += ["--model", model]
        }
        if planMode {
            argv += ["--mode", "plan"]
        } else if autopilot {
            argv += ["--force"]
        }
        argv.append(contentsOf: extraArgs)
        return argv
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
        case .codex:
            return codexArgv(
                model: request.model,
                planMode: request.planMode,
                effort: request.effort,
                autopilot: autopilot,
                workspacePath: workspacePath ?? request.repoKey
            ) ?? []
        case .gemini:
            return geminiArgv(
                model: request.model,
                planMode: request.planMode,
                effort: request.effort,
                autopilot: autopilot,
                trustWorkspace: request.useWorktree && workspacePath != nil && workspacePath != request.repoKey
            ) ?? []
        case .opencode:
            // PR #29: OpenCode sessions don't use tmux argv. The Mac
            // dispatcher routes opencode requests to
            // OpencodeProcessManager + OpencodeSSEAdapter instead.
            return []
        case .cursor:
            return cursorArgv(
                model: request.model,
                // Cursor plan-mode needs a real Cursor chat id for a safe
                // approve/resume cycle. New Clawdmeter-owned Cursor sessions
                // do not have that id yet, so start them directly in code mode.
                planMode: false,
                effort: request.effort,
                autopilot: autopilot,
                workspacePath: workspacePath ?? request.repoKey
            ) ?? []
        case .unknown:
            // X3: forward-compat unknown agent — no argv builder. Caller
            // sees missingBinary and surfaces a clean error.
            return []
        }
    }

    /// v0.8 chat-tab kind-aware dispatch. Branches on `session.kind`:
    /// - `.code`: identical to the NewSessionRequest path above (existing
    ///   code-session behavior).
    /// - `.chat`: forces `planMode = true` for Claude/Codex CLI, ignores
    ///   autopilot, and produces the appropriate per-agent argv.
    ///
    /// **Codex SDK chat** (`session.codexChatBackend == .sdk`) returns an
    /// empty array — the SDK path is handled by `CodexSubscriptionRelay`
    /// directly in Phase 4.5, not through tmux argv. Callers must
    /// detect this case (`session.agent == .codex && session.kind == .chat
    /// && session.codexChatBackend == .sdk`) and route to the relay
    /// instead of spawning a tmux pane.
    ///
    /// **Gemini chat** returns an empty array in v0.8 — the gemini CLI
    /// is being replaced by Antigravity (agy) in a parallel thread; the
    /// Chat tab spawn path lands in v0.9. The /chat-sessions route
    /// handler surfaces 501 Not Implemented for `agent == .gemini` chat
    /// requests.
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
                deepResearch: session.deepResearch
            ) ?? []
        case (.codex, .chat):
            // SDK backend: caller routes to CodexSubscriptionRelay
            // instead of tmux. Empty argv signals "skip tmux spawn".
            if session.codexChatBackend == .sdk { return [] }
            // CLI backend (uniform with Claude/Gemini): tmux + codex
            // --sandbox read-only.
            return codexArgv(
                model: session.model,
                planMode: true,
                effort: session.effort,
                autopilot: false,
                workspacePath: session.effectiveCwd
            ) ?? []
        case (.codex, .code):
            return codexArgv(
                model: session.model,
                planMode: planMode,
                effort: session.effort,
                autopilot: chatAutopilot,
                workspacePath: session.effectiveCwd
            ) ?? []
        case (.gemini, .chat):
            // v0.8: Gemini chat returns 501 at the route handler.
            // Spawn path returns empty to mirror that contract.
            return []
        case (.gemini, .code):
            return geminiArgv(
                model: session.model,
                planMode: planMode,
                effort: session.effort,
                autopilot: chatAutopilot,
                trustWorkspace: session.provisioning != nil
            ) ?? []
        case (.opencode, _):
            // PR #29: opencode sessions don't take a tmux argv.
            // OpencodeProcessManager + SSEAdapter handle spawn.
            return []
        case (.cursor, _):
            // Cursor plan-mode needs a real Cursor resume id for a safe
            // approve/resume cycle. New Clawdmeter-owned chat sessions do
            // not have that id yet, so mirror NewSessionRequest and start
            // Cursor chat in code mode.
            let cursorPlanMode = session.kind == .chat ? false : planMode
            return cursorArgv(
                model: session.model,
                planMode: cursorPlanMode,
                effort: session.effort,
                autopilot: chatAutopilot,
                workspacePath: session.effectiveCwd
            ) ?? []
        case (.unknown, _):
            // X3: forward-compat unknown kind — no argv. Caller surfaces
            // a clean error or routes to a future adapter.
            return []
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
        case .codex:
            return codexArgv(
                model: model,
                planMode: planMode,
                effort: effort,
                autopilot: autopilot,
                acceptEdits: acceptEdits,
                resumeSessionId: resumeSessionId,
                workspacePath: workspacePath
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
        case .opencode:
            // PR #29: opencode has no tmux respawn path.
            return []
        case .cursor:
            return cursorArgv(
                model: model,
                planMode: planMode,
                effort: effort,
                autopilot: autopilot,
                acceptEdits: acceptEdits,
                resumeSessionId: resumeSessionId,
                workspacePath: workspacePath
            ) ?? []
        case .unknown:
            // X3: forward-compat unknown agent — no respawn argv builder.
            return []
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
        if agent == .cursor {
            if cursorBinaryPath() == nil {
                return "Cursor Agent CLI not found or failed identity check: cursor-agent or agent. Configure in Settings → Diagnostics."
            }
            return nil
        }
        let binary = agent.rawValue
        if ShellRunner.locateBinary(binary) == nil {
            return "Agent CLI not found on PATH: \(binary). Configure in Settings → Diagnostics."
        }
        return nil
    }
}
