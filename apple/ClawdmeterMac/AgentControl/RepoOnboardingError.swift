import Foundation
import ClawdmeterShared

/// Mac-side stderr-pattern matchers for the shared `RepoOnboardingError`.
/// The Codable enum and `LocalizedError` conformance live in shared
/// `Protocol.swift` so iOS can decode and display the same shape from daemon
/// responses without Mac adding a retroactive conformance.
extension RepoOnboardingError {
    /// Pattern-match `gh repo clone` / `git clone` stderr against the
    /// known GitHub-auth-failure shapes. Returns `.ghAuthFailed` when the
    /// stderr is unambiguously an authentication problem; nil otherwise.
    /// Cover the three forms we've observed in practice — the messages
    /// vary across `gh` / `git` versions and across HTTPS vs SSH transports.
    public static func matchAuthFailure(stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("authentication failed")
            || lower.contains("could not read username")
            || lower.contains("could not read from remote repository")
            || lower.contains("permission denied (publickey)")
            || lower.contains("401 unauthorized")
            || lower.contains("403 forbidden")
            || lower.contains("gh auth login")
    }

}
