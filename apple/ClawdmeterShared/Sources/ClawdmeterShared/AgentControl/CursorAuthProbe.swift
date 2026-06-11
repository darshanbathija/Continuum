#if os(macOS)
import Foundation

/// Passive + lightweight CLI checks for whether Cursor can authenticate on
/// this Mac. Shared by device discovery, chat-provider probes, and spawn
/// preflight so every surface agrees on the same signals:
///   1. `CURSOR_API_KEY` in the daemon/app process environment
///   2. Cursor.app VS Code storage or `cursor-agent` keychain tokens
///   3. `cursor-agent status` when the above are absent
public enum CursorAuthProbe {

    public static func environmentAPIKey() -> String? {
        let key = ProcessInfo.processInfo.environment["CURSOR_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else { return nil }
        return key
    }

    public static var hasEnvironmentAPIKey: Bool {
        environmentAPIKey() != nil
    }

    public static func hasPassiveStoredCredentials() -> Bool {
        CursorTokenProvider().hasToken
    }

    public static func isStatusOutputAuthenticated(_ output: String) -> Bool {
        let lower = output.lowercased()
        return !lower.contains("not logged in")
            && !lower.contains("not authenticated")
            && !lower.contains("not signed in")
    }

    /// Passive credential checks only — no subprocess. Mac callers that also
    /// need `cursor-agent status` should use `CursorAuthProbeCLI` in the Mac
    /// target.
    public static func hasPassiveAuthentication() -> Bool {
        hasEnvironmentAPIKey || hasPassiveStoredCredentials()
    }
}
#endif
