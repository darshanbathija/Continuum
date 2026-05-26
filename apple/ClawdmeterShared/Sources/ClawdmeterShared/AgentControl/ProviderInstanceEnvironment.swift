import Foundation

/// Builds the explicit child-process environment for a `ProviderInstanceId`
/// when the daemon spawns a per-instance CLI (claude / codex / opencode /
/// cursor / gemini).
///
/// **Codex eng-review #10 (HOME isolation is security-critical).** The
/// F3-wire daemon counterpart to F3 (PR #142). The shape lives in
/// `ProviderInstanceId.homePathOverride`; this helper enforces it on the
/// runtime by:
///   1. Setting `HOME` explicitly to `homePathOverride` (when set) so
///      provider configs (~/.claude/, ~/.codex/, etc.) resolve under
///      the instance's isolated home — never the user's real home.
///   2. **Scrubbing** any inherited `CLAUDE_*` / `CODEX_*` / `ANTHROPIC_*`
///      / `GEMINI_*` / `OPENCODE_*` / `CURSOR_*` env var that belongs to
///      a different instance's authentication / cache state. Prevents
///      a one-account `CLAUDE_API_KEY` from leaking into another
///      instance's spawned child.
///   3. **Preserving** the env vars the CLI legitimately needs (PATH,
///      TMPDIR, USER, LANG, LC_*, TERM, SHELL, …) — anything not on
///      the provider-specific deny-list passes through.
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

    /// Build the explicit env dict for spawning a child process for
    /// `instance`. Inherits everything from `parentEnv` except the
    /// scrubbed prefixes; sets `HOME` to the instance's override when
    /// present, else falls back to the caller's `HOME` (or `userHome`).
    ///
    /// - Parameters:
    ///   - instance: the configured instance whose CLI is being spawned.
    ///   - parentEnv: typically `ProcessInfo.processInfo.environment`.
    ///     Tests pass a deterministic dict.
    ///   - userHome: fallback HOME when neither `instance.homePathOverride`
    ///     nor `parentEnv["HOME"]` is set. Defaults to `ClawdmeterRealHome.path()`.
    /// - Returns: a fully-populated env dict safe to assign to
    ///   `Process.environment`.
    public static func buildEnv(
        for instance: ProviderInstanceId,
        parentEnv: [String: String] = ProcessInfo.processInfo.environment,
        userHome: String? = nil
    ) -> [String: String] {
        var env = parentEnv

        // Strip every scrubbed-prefix var. Iterate over a key snapshot so
        // we don't mutate-while-iterate.
        for key in env.keys {
            if Self.isScrubbed(envKey: key) {
                env.removeValue(forKey: key)
            }
        }

        // Always set HOME explicitly. If the instance has an override,
        // use it; otherwise resolve to the caller's HOME or the real
        // user home. NEVER leave HOME at whatever the parent process
        // happened to have — that's the leak vector this helper exists
        // to close.
        let resolvedHome: String
        if let override = instance.homePathOverride, !override.isEmpty {
            resolvedHome = override
        } else if let parentHome = parentEnv["HOME"], !parentHome.isEmpty {
            resolvedHome = parentHome
        } else if let userHome, !userHome.isEmpty {
            resolvedHome = userHome
        } else {
            resolvedHome = ClawdmeterRealHome.path()
        }
        env["HOME"] = resolvedHome

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
