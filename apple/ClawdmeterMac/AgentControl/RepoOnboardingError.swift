import Foundation
import ClawdmeterShared

/// Mac-side `LocalizedError` conformance + stderr-pattern matchers for the
/// shared `RepoOnboardingError`. The Codable enum itself lives in shared
/// `Protocol.swift` so iOS can decode the same shape from daemon responses;
/// this file is Mac-only because `LocalizedError` is the macOS/UIKit error
/// surfacing mechanism + the stderr matchers are only ever run on the
/// daemon side.
extension RepoOnboardingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pathMissing:
            return "Folder doesn't exist"
        case .notADirectory:
            return "Selected path isn't a folder"
        case .alreadyRegistered:
            return "Already in your projects"
        case .notAGitRepo:
            return "Folder isn't a git repository"
        case .ghAuthFailed:
            return "GitHub authentication failed"
        case .cloneFailed(let stderr):
            return "Clone failed: \(firstLine(stderr))"
        case .gitInitFailed(let stderr):
            return "git init failed: \(firstLine(stderr))"
        case .persistenceFailed(let message):
            return "Couldn't save workspace: \(message)"
        case .pathNotAllowed(let reason):
            return "Path not allowed: \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .pathMissing:
            return "Pick a different folder."
        case .notADirectory:
            return "Select a folder, not a file."
        case .alreadyRegistered:
            return "Open it from the sidebar."
        case .notAGitRepo:
            return "Run `git init` in the folder, or pick a different one."
        case .ghAuthFailed:
            return "Run `gh auth login` in Terminal and try again."
        case .cloneFailed:
            return "Check the URL and your network, then retry."
        case .gitInitFailed:
            return "Make sure the parent folder is writable."
        case .persistenceFailed:
            return "Restart Clawdmeter and try again."
        case .pathNotAllowed:
            return "Pick a folder under your configured default-parent."
        }
    }

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

    private func firstLine(_ s: String) -> String {
        s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? s
    }
}
