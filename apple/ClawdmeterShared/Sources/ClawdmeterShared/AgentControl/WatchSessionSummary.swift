import Foundation

/// Compact session shape pushed from iPhone to Watch via WCSession. The
/// full `AgentSession` is too large for the WatchConnectivity message size
/// limit (~64KB applicationContext). Watch only needs: enough to render
/// a list + a tap-detail action sheet.
///
/// Sessions v2 Phase 6 (T39 watch sibling — main reconciliation gap analysis).
public struct WatchSessionSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let repoDisplayName: String
    public let agent: AgentKind
    public let modelDisplay: String?
    public let status: String        // raw rawValue of AgentSessionStatus
    public let goalSnippet: String?  // first 60 chars
    public let needsAttention: Bool  // planText != nil && status == .planning, etc.
    public let updatedAt: Date
    /// Wire v30: device label for complication / list subtitle.
    public let executionHostLabel: String?

    public init(
        id: UUID,
        repoDisplayName: String,
        agent: AgentKind,
        modelDisplay: String?,
        status: String,
        goalSnippet: String?,
        needsAttention: Bool,
        updatedAt: Date,
        executionHostLabel: String? = nil
    ) {
        self.id = id
        self.repoDisplayName = repoDisplayName
        self.agent = agent
        self.modelDisplay = modelDisplay
        self.status = status
        self.goalSnippet = goalSnippet
        self.needsAttention = needsAttention
        self.updatedAt = updatedAt
        self.executionHostLabel = executionHostLabel
    }

    public static func from(session: AgentSession, modelCatalog: ModelCatalog) -> WatchSessionSummary {
        let modelDisplay: String?
        if let id = session.model, let entry = modelCatalog.entry(forId: id) {
            modelDisplay = entry.displayName
        } else {
            modelDisplay = nil
        }
        let snippet: String?
        if let goal = session.goal, !goal.isEmpty {
            snippet = String(goal.prefix(60))
        } else {
            snippet = nil
        }
        return WatchSessionSummary(
            id: session.id,
            repoDisplayName: session.repoDisplayName,
            agent: session.agent,
            modelDisplay: modelDisplay,
            status: session.status.rawValue,
            goalSnippet: snippet,
            needsAttention: session.planText != nil && session.status == .planning,
            updatedAt: session.lastEventAt,
            executionHostLabel: session.executionHostLabel
        )
    }
}
