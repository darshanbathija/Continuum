import Foundation

/// Builds the explicit child-process environment for a `ProviderInstanceId`
/// when the daemon spawns a per-instance CLI (claude / codex / opencode /
/// cursor / gemini).
///
/// **Codex eng-review #10 (config isolation is security-critical).** The
/// F3-wire daemon counterpart to F3 (PR #142). The shape lives in
/// `ProviderInstanceId.homePathOverride` (the instance config root);
/// this helper enforces it on the runtime by:
///   1. Setting the provider's config-dir var (`CLAUDE_CONFIG_DIR` /
///      `CODEX_HOME`) to the instance's config root so the CLI's auth +
///      history + settings resolve under the isolated root. `HOME`
///      itself is NOT overridden — a full HOME swap would break
///      git/ssh/gh/node for Code sessions.
///   2. **Scrubbing** any inherited `CLAUDE_*` / `CODEX_*` / `ANTHROPIC_*`
///      / `GEMINI_*` / `OPENCODE_*` / `CURSOR_*` env var that belongs to
///      a different instance's authentication / cache state. Prevents
///      a one-account `CLAUDE_API_KEY` from leaking into another
///      instance's spawned child.
///   3. **Preserving** the env vars the CLI legitimately needs (PATH,
///      HOME, TMPDIR, USER, LANG, LC_*, TERM, SHELL, …) — anything not
///      on the provider-specific deny-list passes through.
///   4. **Injecting** per-instance credential vars (`secrets:`) AFTER
///      the scrub, so `CLAUDE_CODE_OAUTH_TOKEN` survives the `CLAUDE_*`
///      strip.
///
/// The output is suitable for `Process.environment = …` or any spawn
/// helper that accepts an explicit env dict. Always returns a fully-
/// populated dict — never `nil` — so callers don't accidentally pass
/// `nil` (which means "inherit caller env unchanged" on
/// `Foundation.Process`, defeating the scrub).
public enum ProviderInstanceEnvironment {

    /// Env var prefixes that are scrubbed when spawning a child process
    /// for a non-primary instance. Centralized here so test coverage
    /// (and future audits) can verify a single, complete list rather
    /// than chasing call-site copies.
    ///
    /// The list matches the auth + cache env contracts published by the
    /// supported CLIs:
    ///   - Claude Code: `CLAUDE_*`, `ANTHROPIC_*`
    ///   - Codex CLI: `CODEX_*`, `OPENAI_*`
    ///   - Gemini CLI / Antigravity: `GEMINI_*`, `GOOGLE_APPLICATION_CREDENTIALS`
    ///   - OpenCode: `OPENCODE_*`, `OPENROUTER_*`
    ///   - Cursor: `CURSOR_*`
    ///
    /// `OPENAI_API_KEY` is on the Codex list because a hostile `OPENAI_API_KEY`
    /// in the parent env would silently override the instance's keychain
    /// token. Same for `OPENROUTER_API_KEY`.
    public static let scrubbedPrefixes: [String] = [
        "CLAUDE_",
        "ANTHROPIC_",
        "CODEX_",
        "OPENAI_",
        "GEMINI_",
        "GOOGLE_APPLICATION_CREDENTIALS", // Exact-match var; treated as a "prefix" of itself
        "OPENCODE_",
        "OPENROUTER_",
        "CURSOR_",
    ]

    /// The env var that points a provider CLI at an isolated config
    /// root. Multi-account v1 (2026-06): we deliberately do NOT override
    /// `HOME` — a full HOME swap breaks git/ssh/gh/node resolution for
    /// Code sessions (worktrees need ~/.gitconfig, ~/.ssh, gh auth).
    /// Each supported CLI exposes its own surgical config-dir var
    /// instead; kinds without one return nil (their instances can't be
    /// config-isolated yet).
    public static func configDirVariable(for kind: AgentKind) -> String? {
        switch kind {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex:  return "CODEX_HOME"
        case .gemini, .opencode, .cursor, .grok, .unknown:
            return nil
        }
    }

    /// Build the explicit env dict for spawning a child process for
    /// `instance`. Inherits everything from `parentEnv` except the
    /// scrubbed prefixes; for a non-primary instance with a config
    /// root, sets the kind's config-dir var (`CLAUDE_CONFIG_DIR` /
    /// `CODEX_HOME`) so the CLI's auth + history + settings resolve
    /// under the instance's isolated root. `HOME` is left alone — see
    /// `configDirVariable(for:)`.
    ///
    /// - Parameters:
    ///   - instance: the configured instance whose CLI is being spawned.
    ///   - parentEnv: typically `ProcessInfo.processInfo.environment`.
    ///     Tests pass a deterministic dict.
    ///   - secrets: per-instance credential vars (e.g.
    ///     `CLAUDE_CODE_OAUTH_TOKEN`) merged AFTER the scrub so the
    ///     `CLAUDE_*` prefix strip can't delete them. Callers fetch
    ///     these from the instance's Keychain partition; this helper
    ///     stays Keychain-free so it's unit-testable.
    /// - Returns: a fully-populated env dict safe to assign to
    ///   `Process.environment`.
    public static func buildEnv(
        for instance: ProviderInstanceId,
        parentEnv: [String: String] = ProcessInfo.processInfo.environment,
        secrets: [String: String] = [:]
    ) -> [String: String] {
        // Primary instance with no secrets ⇒ byte-identical passthrough.
        // Pre-multi-account spawns must not change behavior at all (the
        // primary CLI may rely on user-set CLAUDE_*/CODEX_* env).
        if instance.isPrimary && secrets.isEmpty {
            return parentEnv
        }

        var env = parentEnv

        // Strip every scrubbed-prefix var. Iterate over a key snapshot so
        // we don't mutate-while-iterate.
        for key in env.keys {
            if Self.isScrubbed(envKey: key) {
                env.removeValue(forKey: key)
            }
        }

        // Point the CLI at the instance's isolated config root.
        if let root = instance.homePathOverride, !root.isEmpty,
           let configVar = configDirVariable(for: instance.kind) {
            env[configVar] = root
        }

        // Per-instance credentials last — after the scrub, so an
        // injected CLAUDE_CODE_OAUTH_TOKEN survives the CLAUDE_* strip.
        for (key, value) in secrets {
            env[key] = value
        }

        return env
    }

    /// True when `envKey` matches any of the scrubbed prefixes. Public
    /// so tests can exercise the same matcher the buildEnv path uses.
    public static func isScrubbed(envKey: String) -> Bool {
        for prefix in Self.scrubbedPrefixes {
            // The `GOOGLE_APPLICATION_CREDENTIALS` entry is an exact-name
            // var without a trailing underscore, but `hasPrefix` still
            // matches it cleanly (a string is a prefix of itself).
            if envKey == prefix || envKey.hasPrefix(prefix) {
                return true
            }
        }
        return false
    }
}

/// Redacts secrets / paths from log lines emitted on behalf of a
/// `ProviderInstanceId`. Used by daemon log call sites that would
/// otherwise emit the raw `homePathOverride` value — which leaks the
/// user's filesystem layout into shared log buffers (Console.app,
/// `~/Library/Logs/Clawdmeter/`, telemetry uploads).
///
/// **Contract:** never emit the raw `homePathOverride` value. Replace
/// it with a stable opaque token derived from the instance's wireId
/// so log readers can still correlate events by instance without
/// learning the literal path.
///
/// Codex eng-review #10 acceptance: "never log the raw
/// `homePathOverride` value unscrubbed. Replace with `<HOME for instance
/// kind/name>`."
public enum ProviderInstanceLogRedaction {

    /// Returns the redaction token to substitute in place of the raw
    /// `homePathOverride` value.
    ///
    /// Examples:
    ///   - `.primary(kind: .claude)` → `<HOME for claude/__primary__>`
    ///   - `(kind: .claude, name: "personal", homePathOverride: …)` →
    ///     `<HOME for claude/personal>`
    public static func homeToken(for instance: ProviderInstanceId) -> String {
        "<HOME for \(instance.wireId)>"
    }

    /// Convenience: replace any occurrence of `instance.homePathOverride`
    /// in `message` with the redaction token. No-op when the instance
    /// has no override (the message has nothing to redact — the daemon
    /// is using the user's real HOME).
    public static func redact(_ message: String, for instance: ProviderInstanceId) -> String {
        guard let override = instance.homePathOverride, !override.isEmpty else {
            return message
        }
        return message.replacingOccurrences(of: override, with: homeToken(for: instance))
    }
}
