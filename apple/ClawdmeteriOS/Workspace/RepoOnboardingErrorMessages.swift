import Foundation
import ClawdmeterShared

/// iOS-side user-facing strings for `RepoOnboardingError`. The shared
/// Codable enum stays platform-neutral; the friendly wording lives here
/// so iOS surfaces familiar phrasing instead of raw stderr.
func iosFriendlyMessage(for error: RepoOnboardingError) -> String {
    switch error {
    case .pathMissing:
        return "Folder doesn't exist on the Mac."
    case .notADirectory:
        return "Path isn't a folder."
    case .alreadyRegistered:
        return "Already in your projects."
    case .notAGitRepo:
        return "Folder isn't a git repository."
    case .ghAuthFailed:
        return "GitHub authentication failed. Run `gh auth login` on the Mac."
    case .cloneFailed(let stderr):
        return "Clone failed: \(stderr.split(separator: "\n").first.map(String.init) ?? stderr)"
    case .gitInitFailed(let stderr):
        return "git init failed: \(stderr.split(separator: "\n").first.map(String.init) ?? stderr)"
    case .persistenceFailed(let message):
        return message
    case .pathNotAllowed(let reason):
        return "Path not allowed: \(reason)"
    }
}
