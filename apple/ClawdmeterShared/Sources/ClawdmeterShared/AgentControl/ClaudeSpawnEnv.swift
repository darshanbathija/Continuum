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

    public enum CustomProviderSanitizeError: Error, Equatable {
        case missingCustomBaseURL
    }

    /// Apply custom-provider overrides after the subscription-billing scrub.
    /// Requires a non-empty `ANTHROPIC_BASE_URL` so an auth token can never
    /// be injected while still targeting api.anthropic.com.
    public static func sanitizedWithCustomProvider(
        base: [String: String] = ProcessInfo.processInfo.environment,
        customProviderOverrides: [String: String]
    ) throws -> [String: String] {
        let baseURL = customProviderOverrides["ANTHROPIC_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !baseURL.isEmpty else {
            throw CustomProviderSanitizeError.missingCustomBaseURL
        }
        var env = sanitized(base: base)
        for (key, value) in customProviderOverrides {
            env[key] = value
        }
        return env
    }

    /// True when an environment still carries a credential that would break
    /// subscription billing. Used by tests and a defensive daemon assertion.
    ///
    /// Custom-provider sessions intentionally carry `ANTHROPIC_AUTH_TOKEN` when
    /// `ANTHROPIC_BASE_URL` points at a third-party gateway — only ambient
    /// `ANTHROPIC_API_KEY` counts as a leak in that mode.
    public static func leaksAPICredential(_ env: [String: String]) -> Bool {
        if isCustomAnthropicEndpoint(env) {
            return env["ANTHROPIC_API_KEY"]?.isEmpty == false
        }
        return strippedKeys.contains { env[$0]?.isEmpty == false }
    }

    private static func isCustomAnthropicEndpoint(_ env: [String: String]) -> Bool {
        guard let base = env["ANTHROPIC_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !base.isEmpty else {
            return false
        }
        return !base.lowercased().contains("api.anthropic.com")
    }
}
