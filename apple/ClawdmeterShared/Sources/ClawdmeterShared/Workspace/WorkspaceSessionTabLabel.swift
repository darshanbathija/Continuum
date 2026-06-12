import Foundation

/// Workspace session tab title/subtitle for the Code tab strip.
///
/// Before a short summary exists, tabs read `Repo Name - Branch Name` on one
/// line. Once `customName` or `goal` arrives, the title becomes the first five
/// words of that summary and the branch name moves to the subtitle. Provider
/// names are intentionally omitted to keep crowded strips legible.
public enum WorkspaceSessionTabLabel {
    public struct Labels: Equatable, Sendable {
        public let title: String
        public let subtitle: String

        public init(title: String, subtitle: String) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    public static let summaryWordLimit = 5

    public static func labels(for session: AgentSession) -> Labels {
        let repo = session.repoDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = session.workspaceBranchLabel.trimmingCharacters(in: .whitespacesAndNewlines)

        if let summary = sessionSummary(for: session) {
            return Labels(
                title: ClawdmeterTextUtilities.firstWords(summary, summaryWordLimit),
                subtitle: branch
            )
        }

        return Labels(
            title: repoBranchTitle(repo: repo, branch: branch),
            subtitle: ""
        )
    }

    public static func repoBranchTitle(repo: String, branch: String) -> String {
        let repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repo.isEmpty else { return branch }
        guard !branch.isEmpty, branch != repo else { return repo }
        return "\(repo) - \(branch)"
    }

    private static func sessionSummary(for session: AgentSession) -> String? {
        if let custom = session.customName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        if let goal = session.goal?.trimmingCharacters(in: .whitespacesAndNewlines),
           !goal.isEmpty {
            return goal
        }
        return nil
    }
}
