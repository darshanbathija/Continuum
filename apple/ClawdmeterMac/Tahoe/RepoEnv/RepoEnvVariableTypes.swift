import SwiftUI
import ClawdmeterShared

enum RepoEnvScopeTab: String, CaseIterable, Identifiable {
    case project = "Project"
    case shared = "Shared"

    var id: String { rawValue }
}

enum RepoEnvKindFilter: String, CaseIterable, Identifiable {
    case all = "All Sources"
    case repo = "Repo Only"
    case shared = "Shared Only"

    var id: String { rawValue }
}

enum RepoEnvTypeFilter: String, CaseIterable, Identifiable {
    case all = "All Types"
    case sensitive = "Sensitive"
    case plain = "Plain"
    case system = "System"

    var id: String { rawValue }
}

enum RepoEnvStatusFilter: String, CaseIterable, Identifiable {
    case all = "All Status"
    case inActiveSet = "Active Set"
    case notInActiveSet = "Not Active"
    case conflicts = "Conflicts"
    case disabled = "Disabled"

    var id: String { rawValue }
}

enum RepoEnvSortMode: String, CaseIterable, Identifiable {
    case updatedDesc = "Last Updated"
    case keyAsc = "Name A-Z"
    case keyDesc = "Name Z-A"
    case status = "Status"
    case setCount = "Set Count"

    var id: String { rawValue }
}

enum RepoEnvVariableStatus {
    case active
    case notInActiveSet
    case conflict
    case disabled

    var label: String {
        switch self {
        case .active: return "Active"
        case .notInActiveSet: return "Not active"
        case .conflict: return "Conflict"
        case .disabled: return "Disabled"
        }
    }

    var rank: Int {
        switch self {
        case .conflict: return 0
        case .disabled: return 1
        case .notInActiveSet: return 2
        case .active: return 3
        }
    }

    func color(_ t: TahoeTokens) -> Color {
        switch self {
        case .active: return t.accent
        case .notInActiveSet: return t.fg3
        case .conflict: return .red
        case .disabled: return t.fg4
        }
    }
}

enum RepoEnvEditMode: Identifiable {
    case edit(RepoEnvVariableRecord)
    case rotate(RepoEnvVariableRecord)
    case duplicate(RepoEnvVariableRecord, value: String)

    var id: String {
        switch self {
        case .edit(let variable): return "edit-\(variable.id)"
        case .rotate(let variable): return "rotate-\(variable.id)"
        case .duplicate(let variable, _): return "duplicate-\(variable.id)"
        }
    }

    var variable: RepoEnvVariableRecord {
        switch self {
        case .edit(let variable), .rotate(let variable), .duplicate(let variable, _):
            return variable
        }
    }

    var title: String {
        switch self {
        case .edit: return "Edit Env Variable"
        case .rotate: return "Rotate Env Variable"
        case .duplicate: return "Duplicate Env Variable"
        }
    }

    var isRotate: Bool {
        if case .rotate = self { return true }
        return false
    }
}

struct RepoEnvVariableDraft {
    var key: String
    var value: String
    var note: String
    var kind: RepoEnvVariableKind
    var isEnabled: Bool
    var workspaceIds: Set<UUID>
    var setIds: Set<UUID>
}

struct RepoEnvImportDraft {
    var previews: [RepoEnvImportPreviewRecord]
    var workspaceIds: Set<UUID>
    var setIds: Set<UUID>
    var conflictStrategy: RepoEnvImportConflictStrategy
    var kind: RepoEnvVariableKind
}

extension RepoEnvVariableScope {
    var displayName: String {
        switch self {
        case .local:
            return "repo variable"
        case .shared:
            return "shared variable"
        }
    }
}
