import Foundation

/// Subscription-billing safety rail for every `claude` spawn (Track A).
///
/// **The invariant.** `claude` reuses the user's Pro/Max *subscription* (the
/// flat 5h/weekly pool) ONLY when no API credential is present in its
/// environment. `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` OUTRANK the
/// subscription OAuth login — when either is set, `claude` silently bills
/// pay-per-token at API rates with no error. After the June 15 2026 billing
/// split this also moves usage off the flat pool entirely. So a single stray
/// key in `~/.zshrc` / launchd / the GUI app's inherited env is enough to
/// silently switch billing.
///
/// The PTY host routes every spawn through `sanitized(...)` so an inherited
/// launchd or shell environment cannot silently switch billing modes.
///
/// Pure (`[String: String] -> [String: String]`) so it is unit-testable
/// without a process spawn, and lives in the shared package so the test runs
/// under `swift test`. The PTY host MUST pass the result explicitly and MUST
/// NOT pass `nil` to `PseudoTerminal.spawn` (nil inherits the full daemon env,
/// re-opening the leak) — see `PseudoTerminal.spawn`, whose env parameter is
/// non-defaulting for exactly this reason.
public enum ClaudeSpawnEnv {

    /// Environment variables that force `claude` off the subscription pool.
    /// Removing these is the whole billing invariant.
    public static let strippedKeys: [String] = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
    ]

    /// Return a copy of `base` with the billing-breaking keys removed.
    ///
    /// - Parameter base: the environment to sanitize. Defaults to the current
    ///   process environment — but callers spawning Claude should pass it
    ///   explicitly and feed the result to `PseudoTerminal.spawn(env:)`.
    public static func sanitized(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        for key in strippedKeys {
            env.removeValue(forKey: key)
        }
        return env
    }

    /// True when an environment still carries a credential that would break
    /// subscription billing. Used by tests and a defensive daemon assertion.
    public static func leaksAPICredential(_ env: [String: String]) -> Bool {
        strippedKeys.contains { env[$0]?.isEmpty == false }
    }
}
