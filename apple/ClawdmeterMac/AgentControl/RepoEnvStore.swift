import Foundation
import ClawdmeterShared
import OSLog
import Security

private let repoEnvLogger = Logger(subsystem: "com.clawdmeter.mac", category: "RepoEnvStore")

public enum RepoEnvError: Error, LocalizedError, Equatable {
    case invalidKey(String)
    case workspaceNotFound(String)
    case setNotFound(UUID)
    case variableNotFound(UUID)
    case keychainWriteFailed(String)
    case keychainReadFailed(String)
    case keychainDeleteFailed(String)
    case duplicateKey(String)
    case manualConflicts([RepoEnvConflict])

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let key):
            return "Invalid environment variable key: \(key)"
        case .workspaceNotFound(let repo):
            return "No managed workspace found for \(repo)."
        case .setNotFound:
            return "Environment set not found."
        case .variableNotFound:
            return "Environment variable not found."
        case .keychainWriteFailed(let key):
            return "Could not save \(key) to Keychain."
        case .keychainReadFailed(let key):
            return "Could not read \(key) from Keychain."
        case .keychainDeleteFailed(let key):
            return "Could not delete \(key) from Keychain."
        case .duplicateKey(let key):
            return "\(key) already exists for one of the selected repositories."
        case .manualConflicts(let conflicts):
            let keys = conflicts.map(\.key).sorted().joined(separator: ", ")
            return "Manual .env.local values conflict with managed variables: \(keys)"
        }
    }
}

public struct RepoEnvSetRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let workspaceId: UUID
    public var name: String
    public var slug: String
    public var isActive: Bool
    public var sortOrder: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        workspaceId: UUID,
        name: String,
        slug: String? = nil,
        isActive: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.slug = slug ?? RepoEnvSetRecord.slug(for: name)
        self.isActive = isActive
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func slug(for name: String) -> String {
        let lowered = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let compact = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return compact.isEmpty ? "env" : compact
    }
}

public enum RepoEnvVariableScope: String, Codable, Hashable, Sendable {
    case local
    case shared
}

public enum RepoEnvVariableKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case sensitive
    case plain
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sensitive: return "Sensitive"
        case .plain: return "Plain"
        case .system: return "System"
        }
    }
}

public struct RepoEnvVariableRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public var key: String
    public var scope: RepoEnvVariableScope
    public var kind: RepoEnvVariableKind
    public var note: String?
    public var isEnabled: Bool
    public var valueAccount: String
    public var createdBy: String?
    public var updatedBy: String?
    public var lastRotatedAt: Date?
    public var disabledAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        key: String,
        scope: RepoEnvVariableScope = .local,
        kind: RepoEnvVariableKind = .sensitive,
        note: String? = nil,
        isEnabled: Bool = true,
        valueAccount: String? = nil,
        createdBy: String? = nil,
        updatedBy: String? = nil,
        lastRotatedAt: Date? = nil,
        disabledAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.key = key
        self.scope = scope
        self.kind = kind
        self.note = note
        self.isEnabled = isEnabled
        self.valueAccount = valueAccount ?? "repo-env:\(id.uuidString)"
        self.createdBy = createdBy
        self.updatedBy = updatedBy
        self.lastRotatedAt = lastRotatedAt
        self.disabledAt = disabledAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case key
        case scope
        case kind
        case note
        case isEnabled
        case valueAccount
        case createdBy
        case updatedBy
        case lastRotatedAt
        case disabledAt
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
        scope = try c.decodeIfPresent(RepoEnvVariableScope.self, forKey: .scope) ?? .local
        kind = try c.decodeIfPresent(RepoEnvVariableKind.self, forKey: .kind) ?? .sensitive
        note = try c.decodeIfPresent(String.self, forKey: .note)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        valueAccount = try c.decodeIfPresent(String.self, forKey: .valueAccount) ?? "repo-env:\(id.uuidString)"
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        updatedBy = try c.decodeIfPresent(String.self, forKey: .updatedBy)
        lastRotatedAt = try c.decodeIfPresent(Date.self, forKey: .lastRotatedAt)
        disabledAt = try c.decodeIfPresent(Date.self, forKey: .disabledAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

public enum RepoEnvAuditAction: String, Codable, Hashable, Sendable {
    case created
    case updated
    case valueUpdated
    case rotated
    case deleted
    case assignmentChanged
    case imported
}

public struct RepoEnvAuditEventRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let action: RepoEnvAuditAction
    public let variableId: UUID?
    public let workspaceId: UUID?
    public let actor: String?
    public let message: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        action: RepoEnvAuditAction,
        variableId: UUID? = nil,
        workspaceId: UUID? = nil,
        actor: String? = nil,
        message: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.action = action
        self.variableId = variableId
        self.workspaceId = workspaceId
        self.actor = actor
        self.message = message
        self.createdAt = createdAt
    }
}

public struct RepoEnvImportBatchRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let workspaceIds: [UUID]
    public let importedCount: Int
    public let overwrittenCount: Int
    public let skippedCount: Int
    public let invalidCount: Int
    public let actor: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        workspaceIds: [UUID],
        importedCount: Int,
        overwrittenCount: Int = 0,
        skippedCount: Int = 0,
        invalidCount: Int = 0,
        actor: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workspaceIds = workspaceIds
        self.importedCount = importedCount
        self.overwrittenCount = overwrittenCount
        self.skippedCount = skippedCount
        self.invalidCount = invalidCount
        self.actor = actor
        self.createdAt = createdAt
    }
}

public enum RepoEnvImportPreviewStatus: String, Codable, Hashable, Sendable {
    case ready
    case duplicate
    case invalid
    case emptyValue
    case skipped
}

public struct RepoEnvImportPreviewRecord: Hashable, Identifiable, Sendable {
    public let id: UUID
    public let line: Int
    public let key: String?
    public let value: String?
    public let status: RepoEnvImportPreviewStatus
    public let message: String

    public init(
        id: UUID = UUID(),
        line: Int,
        key: String?,
        value: String?,
        status: RepoEnvImportPreviewStatus,
        message: String
    ) {
        self.id = id
        self.line = line
        self.key = key
        self.value = value
        self.status = status
        self.message = message
    }

    public var canImport: Bool {
        status == .ready || status == .duplicate
    }
}

public enum RepoEnvImportConflictStrategy: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case skip
    case overwrite
    case createDisabledDrafts

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .skip: return "Skip duplicates"
        case .overwrite: return "Overwrite duplicates"
        case .createDisabledDrafts: return "Create disabled drafts"
        }
    }
}

public struct RepoEnvAssignment: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let variableId: UUID
    public let workspaceId: UUID
    public let setId: UUID
    public var isEnabled: Bool
    public var overrideValueAccount: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        variableId: UUID,
        workspaceId: UUID,
        setId: UUID,
        isEnabled: Bool = true,
        overrideValueAccount: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.variableId = variableId
        self.workspaceId = workspaceId
        self.setId = setId
        self.isEnabled = isEnabled
        self.overrideValueAccount = overrideValueAccount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RepoEnvResolvedVariable: Hashable, Sendable {
    public let key: String
    public let value: String
    public let variableId: UUID
    public let assignmentId: UUID
}

public struct RepoEnvConflict: Codable, Hashable, Sendable {
    public let key: String
    public let filePath: String
    public let line: Int
}

public struct RepoEnvResolvedEnvironment: Sendable {
    public let workspace: CodeWorkspaceRecord
    public let set: RepoEnvSetRecord?
    public let variables: [RepoEnvResolvedVariable]
    public let conflicts: [RepoEnvConflict]

    public var environment: [String: String] {
        var env: [String: String] = [:]
        for variable in variables {
            env[variable.key] = variable.value
        }
        return env
    }
}

public protocol RepoEnvSecretStoring: AnyObject, Sendable {
    func read(account: String) -> String?
    func write(_ value: String, account: String) -> Bool
    func delete(account: String) -> Bool
}

public final class RepoEnvKeychainSecretStore: RepoEnvSecretStoring, @unchecked Sendable {
    public static let defaultService = "com.clawdmeter.mac.repo-env"
    private let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    public func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let update = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return true }
        if update != errSecItemNotFound {
            repoEnvLogger.error("Repo env Keychain update failed: \(update, privacy: .public)")
            return false
        }
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            repoEnvLogger.error("Repo env Keychain add failed: \(status, privacy: .public)")
        }
        return status == errSecSuccess
    }

    public func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

@MainActor
public final class RepoEnvStore: ObservableObject {
    @Published public private(set) var sets: [RepoEnvSetRecord] = []
    @Published public private(set) var variables: [RepoEnvVariableRecord] = []
    @Published public private(set) var assignments: [RepoEnvAssignment] = []
    @Published public private(set) var importBatches: [RepoEnvImportBatchRecord] = []
    @Published public private(set) var auditEvents: [RepoEnvAuditEventRecord] = []

    public let secrets: RepoEnvSecretStoring
    private let storeURL: URL

    public init(
        storeURL: URL = RepoEnvStore.defaultStoreURL(),
        secrets: RepoEnvSecretStoring = RepoEnvKeychainSecretStore()
    ) {
        self.storeURL = storeURL
        self.secrets = secrets
        load()
    }

    public nonisolated static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Clawdmeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("repo-env-variables.json")
    }

    public nonisolated static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        let firstOK = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_").contains(first)
        guard firstOK else { return false }
        let restOK = key.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_0123456789").contains($0)
        }
        return restOK
    }

    public func sets(for workspaceId: UUID) -> [RepoEnvSetRecord] {
        sets
            .filter { $0.workspaceId == workspaceId }
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public func activeSet(for workspaceId: UUID) -> RepoEnvSetRecord? {
        let workspaceSets = sets(for: workspaceId)
        return workspaceSets.first(where: \.isActive) ?? workspaceSets.first
    }

    @discardableResult
    public func ensureDefaultSet(workspaceId: UUID) -> RepoEnvSetRecord {
        if let existing = activeSet(for: workspaceId) { return existing }
        return createSet(workspaceId: workspaceId, name: "local", makeActive: true)
    }

    @discardableResult
    public func createSet(workspaceId: UUID, name: String, makeActive: Bool = false) -> RepoEnvSetRecord {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "local" : trimmed
        let existingCount = sets.filter { $0.workspaceId == workspaceId }.count
        let shouldActivate = makeActive || existingCount == 0
        var record = RepoEnvSetRecord(
            workspaceId: workspaceId,
            name: display,
            isActive: shouldActivate,
            sortOrder: existingCount
        )
        if shouldActivate {
            for idx in sets.indices where sets[idx].workspaceId == workspaceId {
                sets[idx].isActive = false
                sets[idx].updatedAt = Date()
            }
        }
        if sets.contains(where: { $0.workspaceId == workspaceId && $0.slug == record.slug }) {
            record.slug = "\(record.slug)-\(existingCount + 1)"
        }
        sets.append(record)
        save()
        return record
    }

    public func setActiveSet(workspaceId: UUID, setId: UUID) {
        for idx in sets.indices where sets[idx].workspaceId == workspaceId {
            sets[idx].isActive = sets[idx].id == setId
            sets[idx].updatedAt = Date()
        }
        save()
    }

    @discardableResult
    public func createVariable(
        key rawKey: String,
        value: String,
        workspaceIds: [UUID],
        scope: RepoEnvVariableScope = .shared,
        kind: RepoEnvVariableKind = .sensitive,
        note: String? = nil,
        isEnabled: Bool = true,
        actor: String? = nil
    ) throws -> RepoEnvVariableRecord {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isValidKey(key) else { throw RepoEnvError.invalidKey(rawKey) }
        let targetWorkspaceIds = Set(workspaceIds)
        let existingIdsInTargets = Set(assignments
            .filter { targetWorkspaceIds.contains($0.workspaceId) }
            .map(\.variableId))
        if variables.contains(where: { $0.key == key && existingIdsInTargets.contains($0.id) }) {
            throw RepoEnvError.duplicateKey(key)
        }
        let now = Date()
        let record = RepoEnvVariableRecord(
            key: key,
            scope: scope,
            kind: kind,
            note: note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            isEnabled: isEnabled,
            createdBy: actor,
            updatedBy: actor,
            disabledAt: isEnabled ? nil : now,
            createdAt: now,
            updatedAt: now
        )
        guard secrets.write(value, account: record.valueAccount) else {
            throw RepoEnvError.keychainWriteFailed(key)
        }
        variables.append(record)
        for workspaceId in workspaceIds {
            let workspaceSets = sets(for: workspaceId)
            let targetSets = workspaceSets.isEmpty
                ? [ensureDefaultSet(workspaceId: workspaceId)]
                : workspaceSets
            for set in targetSets {
                assignments.append(RepoEnvAssignment(
                    variableId: record.id,
                    workspaceId: workspaceId,
                    setId: set.id,
                    isEnabled: true
                ))
            }
        }
        appendAudit(
            action: .created,
            variableId: record.id,
            workspaceId: workspaceIds.first,
            actor: actor,
            message: "Created \(key) for \(workspaceIds.count) repo\(workspaceIds.count == 1 ? "" : "s")."
        )
        save()
        return record
    }

    public func updateVariableValue(variableId: UUID, value: String, markRotated: Bool = false, actor: String? = nil) throws {
        guard let idx = variables.firstIndex(where: { $0.id == variableId }) else {
            throw RepoEnvError.variableNotFound(variableId)
        }
        let key = variables[idx].key
        guard secrets.write(value, account: variables[idx].valueAccount) else {
            throw RepoEnvError.keychainWriteFailed(key)
        }
        let now = Date()
        variables[idx].updatedAt = now
        variables[idx].updatedBy = actor
        if markRotated {
            variables[idx].lastRotatedAt = now
        }
        appendAudit(
            action: markRotated ? .rotated : .valueUpdated,
            variableId: variableId,
            actor: actor,
            message: markRotated ? "Rotated value for \(key)." : "Updated value for \(key)."
        )
        save()
    }

    public func readVariableValue(variableId: UUID) throws -> String {
        guard let variable = variables.first(where: { $0.id == variableId }) else {
            throw RepoEnvError.variableNotFound(variableId)
        }
        guard let value = secrets.read(account: variable.valueAccount) else {
            throw RepoEnvError.keychainReadFailed(variable.key)
        }
        return value
    }

    public func updateVariableMetadata(
        variableId: UUID,
        key rawKey: String,
        note: String?,
        kind: RepoEnvVariableKind,
        isEnabled: Bool,
        actor: String? = nil
    ) throws {
        guard let idx = variables.firstIndex(where: { $0.id == variableId }) else {
            throw RepoEnvError.variableNotFound(variableId)
        }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isValidKey(key) else { throw RepoEnvError.invalidKey(rawKey) }
        if key != variables[idx].key {
            let workspaceIds = assignedWorkspaceIds(variableId: variableId)
            let existingIdsInTargets = Set(assignments
                .filter { workspaceIds.contains($0.workspaceId) }
                .map(\.variableId))
            if variables.contains(where: { $0.id != variableId && $0.key == key && existingIdsInTargets.contains($0.id) }) {
                throw RepoEnvError.duplicateKey(key)
            }
        }
        let now = Date()
        variables[idx].key = key
        variables[idx].note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        variables[idx].kind = kind
        variables[idx].isEnabled = isEnabled
        variables[idx].disabledAt = isEnabled ? nil : (variables[idx].disabledAt ?? now)
        variables[idx].updatedAt = now
        variables[idx].updatedBy = actor
        appendAudit(
            action: .updated,
            variableId: variableId,
            actor: actor,
            message: "Updated metadata for \(key)."
        )
        save()
    }

    public func setAssignment(variableId: UUID, workspaceId: UUID, setId: UUID, enabled: Bool) throws {
        try validateWorkspaceKeyUniqueness(variableId: variableId, workspaceId: workspaceId)
        let now = Date()
        if let idx = assignments.firstIndex(where: {
            $0.variableId == variableId && $0.workspaceId == workspaceId && $0.setId == setId
        }) {
            assignments[idx].isEnabled = enabled
            assignments[idx].updatedAt = now
        } else {
            assignments.append(RepoEnvAssignment(
                variableId: variableId,
                workspaceId: workspaceId,
                setId: setId,
                isEnabled: enabled,
                createdAt: now,
                updatedAt: now
            ))
        }
        if let variable = variables.first(where: { $0.id == variableId }) {
            appendAudit(
                action: .assignmentChanged,
                variableId: variableId,
                workspaceId: workspaceId,
                message: "\(enabled ? "Enabled" : "Disabled") \(variable.key) in one set."
            )
        }
        normalizeScope(variableId: variableId)
        save()
    }

    public func removeAssignments(variableId: UUID, workspaceId: UUID, actor: String? = nil) throws {
        guard let variable = variables.first(where: { $0.id == variableId }) else {
            throw RepoEnvError.variableNotFound(variableId)
        }
        let before = assignments.count
        assignments.removeAll { $0.variableId == variableId && $0.workspaceId == workspaceId }
        guard assignments.count != before else { return }
        normalizeScope(variableId: variableId)
        appendAudit(
            action: .assignmentChanged,
            variableId: variableId,
            workspaceId: workspaceId,
            actor: actor,
            message: "Removed \(variable.key) from one repo."
        )
        save()
    }

    public func deleteVariable(_ variableId: UUID) throws {
        let key = variables.first(where: { $0.id == variableId })?.key
        if let variable = variables.first(where: { $0.id == variableId }),
           !secrets.delete(account: variable.valueAccount) {
            throw RepoEnvError.keychainDeleteFailed(variable.key)
        }
        for assignment in assignments where assignment.variableId == variableId {
            if let account = assignment.overrideValueAccount,
               !secrets.delete(account: account) {
                throw RepoEnvError.keychainDeleteFailed(key ?? variableId.uuidString)
            }
        }
        variables.removeAll { $0.id == variableId }
        assignments.removeAll { $0.variableId == variableId }
        if let key {
            appendAudit(action: .deleted, variableId: variableId, message: "Deleted \(key).")
        }
        save()
    }

    public func variables(for workspaceId: UUID) -> [RepoEnvVariableRecord] {
        let ids = Set(assignments.filter { $0.workspaceId == workspaceId }.map(\.variableId))
        return variables
            .filter { ids.contains($0.id) }
            .sorted { $0.key < $1.key }
    }

    public func assignment(variableId: UUID, workspaceId: UUID, setId: UUID) -> RepoEnvAssignment? {
        assignments.first {
            $0.variableId == variableId && $0.workspaceId == workspaceId && $0.setId == setId
        }
    }

    public func assignedWorkspaceIds(variableId: UUID) -> Set<UUID> {
        Set(assignments.filter { $0.variableId == variableId }.map(\.workspaceId))
    }

    public func auditEvents(for variableId: UUID) -> [RepoEnvAuditEventRecord] {
        auditEvents
            .filter { $0.variableId == variableId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func previewImport(_ text: String, workspaceId: UUID) -> [RepoEnvImportPreviewRecord] {
        let existingKeys = Set(variables(for: workspaceId).map(\.key))
        return RepoEnvImportParser.parse(text).map { preview in
            guard preview.status == .ready, let key = preview.key else { return preview }
            if existingKeys.contains(key) {
                return RepoEnvImportPreviewRecord(
                    line: preview.line,
                    key: key,
                    value: preview.value,
                    status: .duplicate,
                    message: "\(key) already exists in this repo."
                )
            }
            return preview
        }
    }

    @discardableResult
    public func importVariables(
        previews: [RepoEnvImportPreviewRecord],
        workspaceIds: [UUID],
        selectedSetIds: Set<UUID>,
        currentWorkspaceId: UUID,
        conflictStrategy: RepoEnvImportConflictStrategy,
        kind: RepoEnvVariableKind = .sensitive,
        actor: String? = nil
    ) throws -> RepoEnvImportBatchRecord {
        let targetWorkspaceIds = Array(Set(workspaceIds))
        guard !targetWorkspaceIds.isEmpty else {
            throw RepoEnvError.workspaceNotFound("No target repositories selected")
        }
        let invalidCount = previews.filter { $0.status == .invalid || $0.status == .emptyValue }.count
        let candidates = previews.filter(\.canImport)
        for candidate in candidates {
            guard let key = candidate.key, Self.isValidKey(key), candidate.value != nil else {
                throw RepoEnvError.invalidKey(candidate.key ?? "")
            }
        }

        var imported = 0
        var overwritten = 0
        var skipped = invalidCount

        for candidate in candidates {
            guard let key = candidate.key, let value = candidate.value else {
                skipped += 1
                continue
            }
            let existing = existingVariables(key: key, workspaceIds: targetWorkspaceIds)
            if !existing.isEmpty {
                switch conflictStrategy {
                case .skip, .createDisabledDrafts:
                    skipped += 1
                    continue
                case .overwrite:
                    for variable in existing {
                        try updateVariableValue(variableId: variable.id, value: value, actor: actor)
                        try applyImportedAssignments(
                            variableId: variable.id,
                            workspaceIds: targetWorkspaceIds,
                            currentWorkspaceId: currentWorkspaceId,
                            selectedSetIds: selectedSetIds,
                            enabled: true
                        )
                        overwritten += 1
                    }
                    continue
                }
            }

            let record = try createVariable(
                key: key,
                value: value,
                workspaceIds: targetWorkspaceIds,
                scope: targetWorkspaceIds.count > 1 ? .shared : .local,
                kind: kind,
                note: nil,
                isEnabled: conflictStrategy != .createDisabledDrafts,
                actor: actor
            )
            try applyImportedAssignments(
                variableId: record.id,
                workspaceIds: targetWorkspaceIds,
                currentWorkspaceId: currentWorkspaceId,
                selectedSetIds: selectedSetIds,
                enabled: conflictStrategy != .createDisabledDrafts
            )
            imported += 1
        }

        let batch = RepoEnvImportBatchRecord(
            workspaceIds: targetWorkspaceIds,
            importedCount: imported,
            overwrittenCount: overwritten,
            skippedCount: skipped,
            invalidCount: invalidCount,
            actor: actor
        )
        importBatches.append(batch)
        appendAudit(
            action: .imported,
            workspaceId: currentWorkspaceId,
            actor: actor,
            message: "Imported \(imported) env variable\(imported == 1 ? "" : "s"), overwrote \(overwritten), skipped \(skipped)."
        )
        save()
        return batch
    }

    public func resolvedVariables(workspaceId: UUID, setId: UUID) throws -> [RepoEnvResolvedVariable] {
        let variablesById = Dictionary(uniqueKeysWithValues: variables.map { ($0.id, $0) })
        var resolved: [RepoEnvResolvedVariable] = []
        for assignment in assignments where assignment.workspaceId == workspaceId && assignment.setId == setId && assignment.isEnabled {
            guard let variable = variablesById[assignment.variableId], variable.isEnabled else { continue }
            let account = assignment.overrideValueAccount ?? variable.valueAccount
            guard let value = secrets.read(account: account) else {
                throw RepoEnvError.keychainReadFailed(variable.key)
            }
            resolved.append(RepoEnvResolvedVariable(
                key: variable.key,
                value: value,
                variableId: variable.id,
                assignmentId: assignment.id
            ))
        }
        return resolved.sorted { $0.key < $1.key }
    }

    private struct StoreFile: Codable {
        var schemaVersion: Int
        var sets: [RepoEnvSetRecord]
        var variables: [RepoEnvVariableRecord]
        var assignments: [RepoEnvAssignment]
        var importBatches: [RepoEnvImportBatchRecord]
        var auditEvents: [RepoEnvAuditEventRecord]

        init(
            schemaVersion: Int,
            sets: [RepoEnvSetRecord],
            variables: [RepoEnvVariableRecord],
            assignments: [RepoEnvAssignment],
            importBatches: [RepoEnvImportBatchRecord],
            auditEvents: [RepoEnvAuditEventRecord]
        ) {
            self.schemaVersion = schemaVersion
            self.sets = sets
            self.variables = variables
            self.assignments = assignments
            self.importBatches = importBatches
            self.auditEvents = auditEvents
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case sets
            case variables
            case assignments
            case importBatches
            case auditEvents
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            sets = try c.decodeIfPresent([RepoEnvSetRecord].self, forKey: .sets) ?? []
            variables = try c.decodeIfPresent([RepoEnvVariableRecord].self, forKey: .variables) ?? []
            assignments = try c.decodeIfPresent([RepoEnvAssignment].self, forKey: .assignments) ?? []
            importBatches = try c.decodeIfPresent([RepoEnvImportBatchRecord].self, forKey: .importBatches) ?? []
            auditEvents = try c.decodeIfPresent([RepoEnvAuditEventRecord].self, forKey: .auditEvents) ?? []
        }
    }

    private static let currentSchemaVersion = 2

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(StoreFile.self, from: data)
            sets = file.sets
            variables = file.variables
            assignments = file.assignments
            importBatches = file.importBatches
            auditEvents = file.auditEvents
        } catch {
            repoEnvLogger.error("Failed to load repo env store: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let file = StoreFile(
            schemaVersion: Self.currentSchemaVersion,
            sets: sets,
            variables: variables,
            assignments: assignments,
            importBatches: importBatches,
            auditEvents: auditEvents
        )
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(file)
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            repoEnvLogger.error("Failed to save repo env store: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func existingVariables(key: String, workspaceIds: [UUID]) -> [RepoEnvVariableRecord] {
        let ids = Set(assignments
            .filter { workspaceIds.contains($0.workspaceId) }
            .map(\.variableId))
        return variables.filter { $0.key == key && ids.contains($0.id) }
    }

    private func applyImportedAssignments(
        variableId: UUID,
        workspaceIds: [UUID],
        currentWorkspaceId: UUID,
        selectedSetIds: Set<UUID>,
        enabled: Bool
    ) throws {
        for workspaceId in workspaceIds {
            let targetSets = sets(for: workspaceId).isEmpty
                ? [ensureDefaultSet(workspaceId: workspaceId)]
                : sets(for: workspaceId)
            let enabledSetIds = workspaceId == currentWorkspaceId && !selectedSetIds.isEmpty
                ? selectedSetIds
                : Set(targetSets.map(\.id))
            for set in targetSets {
                try setAssignmentWithoutSaving(
                    variableId: variableId,
                    workspaceId: workspaceId,
                    setId: set.id,
                    enabled: enabled && enabledSetIds.contains(set.id)
                )
            }
        }
    }

    private func setAssignmentWithoutSaving(variableId: UUID, workspaceId: UUID, setId: UUID, enabled: Bool) throws {
        try validateWorkspaceKeyUniqueness(variableId: variableId, workspaceId: workspaceId)
        let now = Date()
        if let idx = assignments.firstIndex(where: {
            $0.variableId == variableId && $0.workspaceId == workspaceId && $0.setId == setId
        }) {
            assignments[idx].isEnabled = enabled
            assignments[idx].updatedAt = now
        } else {
            assignments.append(RepoEnvAssignment(
                variableId: variableId,
                workspaceId: workspaceId,
                setId: setId,
                isEnabled: enabled,
                createdAt: now,
                updatedAt: now
            ))
        }
        normalizeScope(variableId: variableId)
    }

    private func validateWorkspaceKeyUniqueness(variableId: UUID, workspaceId: UUID) throws {
        guard let variable = variables.first(where: { $0.id == variableId }) else {
            throw RepoEnvError.variableNotFound(variableId)
        }
        let conflictingVariableIds = Set(assignments
            .filter { $0.workspaceId == workspaceId && $0.variableId != variableId }
            .map(\.variableId))
        if variables.contains(where: { $0.key == variable.key && conflictingVariableIds.contains($0.id) }) {
            throw RepoEnvError.duplicateKey(variable.key)
        }
    }

    private func normalizeScope(variableId: UUID) {
        guard let idx = variables.firstIndex(where: { $0.id == variableId }) else { return }
        let workspaceCount = Set(assignments
            .filter { $0.variableId == variableId }
            .map(\.workspaceId))
            .count
        variables[idx].scope = workspaceCount > 1 ? .shared : .local
    }

    private func appendAudit(
        action: RepoEnvAuditAction,
        variableId: UUID? = nil,
        workspaceId: UUID? = nil,
        actor: String? = nil,
        message: String
    ) {
        auditEvents.append(RepoEnvAuditEventRecord(
            action: action,
            variableId: variableId,
            workspaceId: workspaceId,
            actor: actor,
            message: message
        ))
        if auditEvents.count > 500 {
            auditEvents.removeFirst(auditEvents.count - 500)
        }
    }
}

public enum RepoEnvImportParser {
    public static func parse(_ text: String) -> [RepoEnvImportPreviewRecord] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [RepoEnvImportPreviewRecord] = []
        var index = 0

        while index < lines.count {
            let lineNumber = index + 1
            var line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                result.append(RepoEnvImportPreviewRecord(
                    line: lineNumber,
                    key: nil,
                    value: nil,
                    status: .skipped,
                    message: trimmed.isEmpty ? "Blank line" : "Comment"
                ))
                index += 1
                continue
            }

            let body = trimmed.hasPrefix("export ")
                ? String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
                : trimmed
            guard let eq = body.firstIndex(of: "=") else {
                result.append(RepoEnvImportPreviewRecord(
                    line: lineNumber,
                    key: nil,
                    value: nil,
                    status: .invalid,
                    message: "Missing = separator."
                ))
                index += 1
                continue
            }

            let rawKey = String(body[..<eq]).trimmingCharacters(in: .whitespaces)
            let key = rawKey.uppercased()
            guard RepoEnvStore.isValidKey(key) else {
                result.append(RepoEnvImportPreviewRecord(
                    line: lineNumber,
                    key: rawKey.isEmpty ? nil : rawKey,
                    value: nil,
                    status: .invalid,
                    message: "Invalid key."
                ))
                index += 1
                continue
            }

            var rawValue = String(body[body.index(after: eq)...])
            if let quote = rawValue.first, quote == "\"" || quote == "'" {
                while !hasClosingQuote(rawValue, quote: quote), index + 1 < lines.count {
                    index += 1
                    line = lines[index]
                    rawValue += "\n" + line
                }
            }

            let value = decodeValue(rawValue)
            result.append(RepoEnvImportPreviewRecord(
                line: lineNumber,
                key: key,
                value: value,
                status: value.isEmpty ? .emptyValue : .ready,
                message: value.isEmpty ? "Empty value." : "Ready to import."
            ))
            index += 1
        }

        return result
    }

    private static func hasClosingQuote(_ value: String, quote: Character) -> Bool {
        guard value.first == quote else { return true }
        var escaped = false
        for ch in value.dropFirst() {
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" {
                escaped = true
                continue
            }
            if ch == quote {
                return true
            }
        }
        return false
    }

    private static func decodeValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), let end = closingQuoteIndex(in: value, quote: "\"") {
            value = String(value[value.index(after: value.startIndex)..<end])
            return decodeDoubleQuoted(value)
        }
        if value.hasPrefix("'"), let end = closingQuoteIndex(in: value, quote: "'") {
            return String(value[value.index(after: value.startIndex)..<end])
        }
        if let comment = value.range(of: " #") {
            value = String(value[..<comment.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func closingQuoteIndex(in value: String, quote: Character) -> String.Index? {
        var escaped = false
        var idx = value.index(after: value.startIndex)
        while idx < value.endIndex {
            let ch = value[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == quote {
                return idx
            }
            idx = value.index(after: idx)
        }
        return nil
    }

    private static func decodeDoubleQuoted(_ value: String) -> String {
        var decoded = ""
        var escaped = false
        for ch in value {
            if escaped {
                switch ch {
                case "n": decoded.append("\n")
                case "r": decoded.append("\r")
                case "t": decoded.append("\t")
                default: decoded.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                decoded.append(ch)
            }
        }
        if escaped {
            decoded.append("\\")
        }
        return decoded
    }
}

public final class RepoEnvFileMaterializer: @unchecked Sendable {
    public static let beginMarker = "# >>> Clawdmeter managed env variables"
    public static let endMarker = "# <<< Clawdmeter managed env variables"

    public init() {}

    public func inspectManualKeys(fileURL: URL) -> [RepoEnvConflict] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return manualKeys(in: text, filePath: fileURL.path)
    }

    public func materialize(
        variables: [RepoEnvResolvedVariable],
        cwd: String
    ) throws -> [RepoEnvConflict] {
        let url = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(".env.local")
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let manual = manualKeys(in: original, filePath: url.path)
        let managedKeys = Set(variables.map(\.key))
        let conflicts = manual.filter { managedKeys.contains($0.key) }
        guard conflicts.isEmpty else { return conflicts }

        let block = managedBlock(for: variables)
        let updated = replaceManagedBlock(in: original, with: block)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return []
    }

    private func managedBlock(for variables: [RepoEnvResolvedVariable]) -> String {
        var lines: [String] = [Self.beginMarker]
        lines.append("# This block is owned by Clawdmeter. Edit repo env settings instead.")
        for variable in variables.sorted(by: { $0.key < $1.key }) {
            lines.append("\(variable.key)=\(Self.encodeEnvValue(variable.value))")
        }
        lines.append(Self.endMarker)
        return lines.joined(separator: "\n")
    }

    private func replaceManagedBlock(in original: String, with block: String) -> String {
        let normalizedBlock = block + "\n"
        guard let begin = original.range(of: Self.beginMarker),
              let end = original.range(of: Self.endMarker, range: begin.upperBound..<original.endIndex)
        else {
            let prefix = original.isEmpty || original.hasSuffix("\n") ? original : original + "\n"
            return prefix + normalizedBlock
        }
        var replaceEnd = end.upperBound
        if replaceEnd < original.endIndex, original[replaceEnd] == "\n" {
            replaceEnd = original.index(after: replaceEnd)
        }
        var updated = original
        updated.replaceSubrange(begin.lowerBound..<replaceEnd, with: normalizedBlock)
        return updated
    }

    private func manualKeys(in text: String, filePath: String) -> [RepoEnvConflict] {
        var inManagedBlock = false
        var result: [RepoEnvConflict] = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(rawLine)
            if line.contains(Self.beginMarker) {
                inManagedBlock = true
                continue
            }
            if line.contains(Self.endMarker) {
                inManagedBlock = false
                continue
            }
            guard !inManagedBlock,
                  let key = Self.key(inEnvLine: line)
            else { continue }
            result.append(RepoEnvConflict(key: key, filePath: filePath, line: offset + 1))
        }
        return result
    }

    public static func key(inEnvLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        let body = trimmed.hasPrefix("export ")
            ? String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            : trimmed
        guard let eq = body.firstIndex(of: "=") else { return nil }
        let key = String(body[..<eq]).trimmingCharacters(in: .whitespaces)
        return RepoEnvStore.isValidKey(key) ? key : nil
    }

    public static func encodeEnvValue(_ value: String) -> String {
        if value.isEmpty { return "\"\"" }
        let simple = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:-")
        if value.unicodeScalars.allSatisfy({ simple.contains($0) }) {
            return value
        }
        var escaped = ""
        for ch in value {
            switch ch {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "$": escaped += "\\$"
            case "`": escaped += "\\`"
            case "\n": escaped += "\\n"
            default: escaped.append(ch)
            }
        }
        return "\"\(escaped)\""
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

@MainActor
public final class RepoEnvRuntimeResolver {
    private let workspaceStore: WorkspaceStore
    private let envStore: RepoEnvStore
    private let materializer: RepoEnvFileMaterializer

    public init(
        workspaceStore: WorkspaceStore,
        envStore: RepoEnvStore,
        materializer: RepoEnvFileMaterializer = RepoEnvFileMaterializer()
    ) {
        self.workspaceStore = workspaceStore
        self.envStore = envStore
        self.materializer = materializer
    }

    public func resolveForLaunch(
        repoRoot: String?,
        cwd: String,
        envSetId: UUID? = nil,
        materialize: Bool = true
    ) throws -> RepoEnvResolvedEnvironment? {
        guard let repoRoot,
              let workspace = workspaceStore.workspace(forRepoRoot: repoRoot)
        else { return nil }
        let set: RepoEnvSetRecord?
        if let envSetId {
            guard let found = envStore.sets(for: workspace.id).first(where: { $0.id == envSetId }) else {
                throw RepoEnvError.setNotFound(envSetId)
            }
            set = found
        } else {
            set = envStore.activeSet(for: workspace.id)
        }
        guard let selectedSet = set else {
            return RepoEnvResolvedEnvironment(workspace: workspace, set: nil, variables: [], conflicts: [])
        }
        let variables = try envStore.resolvedVariables(workspaceId: workspace.id, setId: selectedSet.id)
        let conflicts = materialize
            ? try materializer.materialize(variables: variables, cwd: cwd)
            : []
        guard conflicts.isEmpty else { throw RepoEnvError.manualConflicts(conflicts) }
        return RepoEnvResolvedEnvironment(
            workspace: workspace,
            set: selectedSet,
            variables: variables,
            conflicts: conflicts
        )
    }

    public func resolveForLaunch(
        session: AgentSession,
        cwd: String? = nil,
        materialize: Bool = true
    ) throws -> RepoEnvResolvedEnvironment? {
        try resolveForLaunch(
            repoRoot: session.repoKey,
            cwd: cwd ?? session.effectiveCwd,
            envSetId: session.envSetId,
            materialize: materialize
        )
    }

    public func materializeActiveSet(repoRoot: String) throws -> RepoEnvResolvedEnvironment? {
        try resolveForLaunch(repoRoot: repoRoot, cwd: repoRoot, envSetId: nil, materialize: true)
    }
}
