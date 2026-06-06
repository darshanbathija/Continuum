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

extension RepoOnboardingError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pathMissing:
            return "Folder doesn't exist."
        case .notADirectory:
            return "Path isn't a folder."
        case .alreadyRegistered:
            return "Already in your projects."
        case .notAGitRepo:
            return "Folder isn't a git repository."
        case .ghAuthFailed:
            return "GitHub authentication failed."
        case .cloneFailed(let stderr):
            return "Clone failed: \(Self.firstLine(stderr))"
        case .gitInitFailed(let stderr):
            return "git init failed: \(Self.firstLine(stderr))"
        case .persistenceFailed(let message):
            return message
        case .pathNotAllowed(let reason):
            return "Path not allowed: \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .pathMissing:
            return "Choose an existing folder and try again."
        case .notADirectory:
            return "Choose a folder, not a file."
        case .alreadyRegistered:
            return nil
        case .notAGitRepo:
            return "Pick a repository folder or clone from GitHub."
        case .ghAuthFailed:
            return "Run `gh auth login` on this Mac and try again."
        case .cloneFailed:
            return "Check the repo name and your GitHub access."
        case .gitInitFailed:
            return "Check folder permissions and try again."
        case .persistenceFailed:
            return "Try again. If it repeats, restart Continuum."
        case .pathNotAllowed:
            return "Choose a folder under an allowed workspace root."
        }
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map(String.init) ?? text
    }
}
