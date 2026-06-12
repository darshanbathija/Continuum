import Foundation
import ClawdmeterShared

enum PRPromptResolver {
    static let promptText = "Create a PR"
    static let attachmentDisplayName = "PR instructions.md"
    private static let bundledResourceName = "PR instructions"

    private static let candidateRelativePaths = [
        ".context/PR instructions.md",
        ".context/pr instructions.md",
        ".context/PR-instructions.md",
        "PR instructions.md",
    ]

    /// Resolves the PR skill file to attach when the user taps Create PR.
    /// Prefers a workspace-local Conductor-style `.context/PR instructions.md`,
    /// then falls back to the bundled Continuum default skill.
    static func instructionsFileURL(for session: AgentSession) -> URL? {
        for root in searchRoots(for: session) {
            for relative in candidateRelativePaths {
                let url = URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        return bundledInstructionsURL()
    }

    static func bundledInstructionsURL() -> URL? {
        Bundle.main.url(forResource: bundledResourceName, withExtension: "md")
    }

    private static func searchRoots(for session: AgentSession) -> [String] {
        var roots: [String] = []
        if let worktree = session.worktreePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !worktree.isEmpty {
            roots.append(WorkspaceKey.canonicalPath(worktree))
        }
        let cwd = session.effectiveCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cwd.isEmpty {
            roots.append(WorkspaceKey.canonicalPath(cwd))
        }
        if let repoKey = session.repoKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !repoKey.isEmpty {
            roots.append(WorkspaceKey.canonicalPath(repoKey))
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }
}
