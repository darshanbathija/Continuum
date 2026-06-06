import Foundation
import OSLog
import ClawdmeterShared

private let authObserverLogger = Logger(subsystem: "com.clawdmeter.mac", category: "ChatProviderAuthObserver")

/// v0.9.x — CM3 auth observer.
///
/// Sources of "this provider's OAuth tokens are no longer valid":
///   1. **Claude JSONL `error.type`**: Claude Code writes
///      `{type: "error", error: {type: "oauth-expired" | "invalid_api_key"
///      | "authentication_error", message: "..."}}` lines into the
///      project JSONL when its OAuth wedge expires mid-turn.
///   2. **Codex JSONL `payload.error`**: Codex CLI rollouts include
///      `{payload: {error: "token-expired" | "invalid_token", ...}}`
///      response_item rows when the ChatGPT auth header is stale.
/// This observer doesn't run a full scanner — it offers `record(...)`
/// hooks the existing ingest/send paths call when they encounter one
/// of the signals above. Each hook:
///   1. Flips the corresponding `ChatProviderProbe` override to
///      `authenticated=false` so the next `/chat-providers` probe
///      surfaces the failure to iOS Chat tab Settings.
///   2. Emits an AgentEvent so live UIs see the change without
///      polling.
///
/// The shared instance is wired from `AgentControlServer` (probe +
/// event-stream injection) so consumers don't need to thread refs.
public actor ChatProviderAuthObserver {

    public static let shared = ChatProviderAuthObserver()

    public init() {}

    /// Claude JSONL parser hook — call when a `type: "error"` line
    /// surfaces with `error.type` matching one of the auth-class
    /// strings. Idempotent on repeat signals.
    public func recordClaudeAuthError(sessionId: UUID?, errorType: String, message: String?) async {
        guard isAuthError(errorType) else { return }
        authObserverLogger.warning("Claude auth error type=\(errorType, privacy: .public) — flipping probe to authenticated=false")
        await ChatProviderProbe.shared.setAuthOverride(
            providerKey: "claude",
            authenticated: false,
            reason: message ?? "Claude OAuth expired — re-run `claude` in Terminal to re-authenticate."
        )
        // v0.9.x: no AgentEvent emission for auth flips — probe state is
        // poll-driven and the override sticks until cleared. v0.9.x.1
        // could add a dedicated `providerAuthFailed` AgentEventKind case
        // (additive on the wire) to push live UIs without polling, but
        // it's not the v0.9.x ship-gate.
        _ = sessionId
    }

    /// Codex CLI JSONL response_item parser hook — call when a
    /// `payload.error` field surfaces with an auth-class string.
    public func recordCodexCLIAuthError(sessionId: UUID?, errorString: String) async {
        guard isAuthError(errorString) else { return }
        authObserverLogger.warning("Codex CLI auth error=\(errorString, privacy: .public) — flipping probe to authenticated=false")
        await ChatProviderProbe.shared.setAuthOverride(
            providerKey: "codex",
            authenticated: false,
            reason: "Codex ChatGPT auth expired — run `codex` in Terminal and re-sign-in."
        )
        _ = sessionId
        _ = errorString
    }

    /// Manual clear (e.g. user clicked "Try again" after re-auth in
    /// Settings). Drops the override so the next probe re-derives auth
    /// state from the binary check.
    public func clear(providerKey: String) async {
        await ChatProviderProbe.shared.clearAuthOverride(providerKey: providerKey)
    }

    // MARK: - Heuristics

    /// Anthropic/OpenAI auth error vocabulary. New strings will surface
    /// as no-ops until added here — that's the right default (false
    /// positive on auth detection is worse than false negative).
    private func isAuthError(_ raw: String) -> Bool {
        let normalized = raw.lowercased()
        return normalized.contains("oauth") ||
               normalized.contains("authentication") ||
               normalized.contains("invalid_api_key") ||
               normalized.contains("invalid_token") ||
               normalized.contains("token-expired") ||
               normalized.contains("token_expired") ||
               normalized.contains("401")
    }
}
