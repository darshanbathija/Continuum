import Foundation
import ClawdmeterShared

struct IOSWorkspaceDocumentTab: Identifiable, Equatable {
    let id: UUID
    let sessionId: UUID
    let workspaceKey: WorkspaceKey
    let path: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        workspaceKey: WorkspaceKey,
        path: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.workspaceKey = workspaceKey
        self.path = path
        self.createdAt = createdAt
    }

    var title: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "Markdown" : name
    }
}

enum IOSWorkspaceDocumentTabs {
    static func tabs(
        in workspaceKey: WorkspaceKey,
        all tabs: [IOSWorkspaceDocumentTab]
    ) -> [IOSWorkspaceDocumentTab] {
        tabs
            .filter { $0.workspaceKey == workspaceKey }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    @discardableResult
    static func open(
        tabs: inout [IOSWorkspaceDocumentTab],
        selectedId: inout UUID?,
        session: AgentSession,
        path: String,
        createdAt: Date = Date()
    ) -> IOSWorkspaceDocumentTab? {
        guard let workspaceKey = WorkspaceKey.of(session) else { return nil }
        let standardized = standardizedPath(path, relativeTo: session.effectiveCwd)
        guard !standardized.isEmpty else { return nil }
        if let existing = tabs.first(where: {
            $0.workspaceKey == workspaceKey && standardizedPath($0.path, relativeTo: session.effectiveCwd) == standardized
        }) {
            selectedId = existing.id
            return existing
        }
        let tab = IOSWorkspaceDocumentTab(
            sessionId: session.id,
            workspaceKey: workspaceKey,
            path: standardized,
            createdAt: createdAt
        )
        tabs.append(tab)
        selectedId = tab.id
        return tab
    }

    static func close(
        tabs: inout [IOSWorkspaceDocumentTab],
        selectedId: inout UUID?,
        tab: IOSWorkspaceDocumentTab
    ) {
        tabs.removeAll { $0.id == tab.id }
        if selectedId == tab.id {
            selectedId = nil
        }
    }

    static func standardizedPath(_ path: String, relativeTo cwd: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            return trimmed
        }
        let absolute: String
        if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else {
            absolute = (cwd as NSString).appendingPathComponent(trimmed)
        }
        return WorkspaceKey.canonicalPath(absolute)
    }
}
