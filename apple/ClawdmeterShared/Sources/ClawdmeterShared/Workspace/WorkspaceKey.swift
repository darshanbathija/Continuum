import Foundation

/// Derived identity for the Code workspace tab strip.
///
/// This is intentionally not the git branch name. Conductor-style
/// workspaces and user-created worktrees can have a path (`kolkata`) that
/// does not match the checked-out branch (`darshanbathija/session-tabs`).
/// Group by the actual runtime cwd/worktree path so "same workspace" means
/// "same filesystem sandbox".
public struct WorkspaceKey: Hashable, Sendable, Codable {
    public let repoKey: String
    public let workspacePath: String

    public init(repoKey: String, workspacePath: String) {
        self.repoKey = Self.canonicalPath(repoKey)
        self.workspacePath = Self.canonicalPath(workspacePath)
    }

    public static func of(_ session: AgentSession) -> WorkspaceKey? {
        guard session.kind == .code,
              let repo = session.repoKey,
              !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let workspacePath = Self.workspacePath(for: session)
        return WorkspaceKey(repoKey: repo, workspacePath: workspacePath)
    }

    public static func workspacePath(for session: AgentSession) -> String {
        if let cwd = session.runtimeCwd, !cwd.isEmpty { return cwd }
        if let worktree = session.worktreePath, !worktree.isEmpty { return worktree }
        return session.repoKey ?? session.effectiveCwd
    }

    public static func siblings(
        of key: WorkspaceKey,
        in sessions: [AgentSession],
        excluding excludedId: UUID? = nil
    ) -> [AgentSession] {
        sessions
            .filter { session in
                guard session.kind == .code,
                      session.archivedAt == nil,
                      session.id != excludedId,
                      let sessionKey = WorkspaceKey.of(session)
                else { return false }
                return sessionKey == key
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public static func siblings(
        of session: AgentSession,
        in sessions: [AgentSession]
    ) -> [AgentSession] {
        guard let key = WorkspaceKey.of(session) else { return [] }
        return siblings(of: key, in: sessions, excluding: session.id)
    }

    public static func canonicalPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let standardized = (trimmed as NSString).standardizingPath
        return (standardized as NSString).resolvingSymlinksInPath
    }
}
