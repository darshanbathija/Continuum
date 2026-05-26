import Foundation

/// Indirection so OAuth token loading can be mocked in tests and varied per
/// platform.
///
/// Implementations:
/// - `KeychainTokenProvider` (macOS / iOS) — explicit one-shot importer for
///   Claude Code's OAuth token in the system Keychain.
/// - `PastedAnthropicTokenProvider` (macOS / iOS / watchOS) — Clawdmeter-owned,
///   iCloud-Keychain-synced entry used for normal Anthropic polling.
/// - `CodexTokenProvider` (all Apple platforms) — Codex `auth.json` file reader.
/// - `LinuxSecretServiceTokenProvider` (Linux) — `libsecret-1` D-Bus
///   Secret Service API; falls back to `~/.config/clawdmeter/.token` chmod 0600
///   when no Secret Service daemon is running (headless / server installs).
///
/// The protocol itself is pure-Foundation and compiles on every platform Swift
/// supports. The Linux Hummingbird daemon consumes implementations via `await`.
public protocol TokenProvider: Sendable {
    /// The current access token, or `nil` if none cached. Reading is fast (in-memory).
    var currentAccessToken: String? { get }

    /// True if `currentAccessToken` would return a value.
    var hasToken: Bool { get }

    /// Refresh if the cached token is near expiry.
    /// - Returns: true if a refresh was performed, false if no refresh was needed.
    /// - Throws: on hard failure (refresh token missing / Keychain access denied / etc.)
    func refreshIfNeeded() async throws -> Bool
}
