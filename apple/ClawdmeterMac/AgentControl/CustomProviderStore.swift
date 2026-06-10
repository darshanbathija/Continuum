import Foundation
import Security
import ClawdmeterShared
import OSLog

private let customProviderLogger = Logger(subsystem: "com.clawdmeter.mac", category: "CustomProviderStore")

public enum CustomProviderStoreError: Error, LocalizedError, Equatable {
    case invalidBaseURL(String)
    case duplicateId(String)
    case providerNotFound(String)
    case keyUnavailable(String)
    case keychainWriteFailed
    case keychainDeleteFailed

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let url):
            return "Invalid base URL: \(url)"
        case .duplicateId(let id):
            return "A custom provider with id \"\(id)\" already exists."
        case .providerNotFound(let id):
            return "Custom provider \"\(id)\" not found."
        case .keyUnavailable(let detail):
            return detail
        case .keychainWriteFailed:
            return "Could not save the API key to Keychain."
        case .keychainDeleteFailed:
            return "Could not delete the API key from Keychain."
        }
    }
}

public struct CustomProviderModel: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }
}

public struct CustomProviderTestOutcome: Codable, Hashable, Sendable {
    public let success: Bool
    public let modelCount: Int?
    public let httpStatus: Int?
    public let errorDetail: String?
    public let testedAt: Date

    public init(
        success: Bool,
        modelCount: Int? = nil,
        httpStatus: Int? = nil,
        errorDetail: String? = nil,
        testedAt: Date = Date()
    ) {
        self.success = success
        self.modelCount = modelCount
        self.httpStatus = httpStatus
        self.errorDetail = errorDetail
        self.testedAt = testedAt
    }
}

public struct CustomProviderRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var label: String
    public var kind: CustomProviderKind
    public var baseURL: String
    public var keySource: CustomProviderKeySource
    public var isEnabled: Bool
    public var defaultModelId: String?
    public var models: [CustomProviderModel]
    public var modelsFetchedAt: Date?
    public var lastTestResult: CustomProviderTestOutcome?
    public let createdAt: Date
    public var updatedAt: Date

    public var keychainAccount: String { "custom-provider:\(id)" }

    public var codexEnvKeyName: String {
        let normalized = id.uppercased().replacingOccurrences(of: "-", with: "_")
        return "CLAWDMETER_CP_\(normalized)_API_KEY"
    }

    public var displayLabel: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return Self.hostLabel(from: baseURL) ?? id
    }

    public init(
        id: String,
        label: String,
        kind: CustomProviderKind,
        baseURL: String,
        keySource: CustomProviderKeySource,
        isEnabled: Bool = true,
        defaultModelId: String? = nil,
        models: [CustomProviderModel] = [],
        modelsFetchedAt: Date? = nil,
        lastTestResult: CustomProviderTestOutcome? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.baseURL = baseURL
        self.keySource = keySource
        self.isEnabled = isEnabled
        self.defaultModelId = defaultModelId
        self.models = models
        self.modelsFetchedAt = modelsFetchedAt
        self.lastTestResult = lastTestResult
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func hostLabel(from baseURL: String) -> String? {
        guard let url = URL(string: baseURL), let host = url.host, !host.isEmpty else { return nil }
        return host
    }
}

public protocol CustomProviderSecretStoring: AnyObject, Sendable {
    func read(account: String) -> String?
    func write(_ value: String, account: String) -> Bool
    func delete(account: String) -> Bool
}

public final class CustomProviderKeychainSecretStore: CustomProviderSecretStoring, @unchecked Sendable {
    public static let defaultService = "com.clawdmeter.mac.custom-providers"
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
            customProviderLogger.error("Custom provider Keychain update failed: \(update, privacy: .public)")
            return false
        }
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            customProviderLogger.error("Custom provider Keychain add failed: \(status, privacy: .public)")
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
public final class CustomProviderStore: ObservableObject {
    @Published public private(set) var records: [CustomProviderRecord] = []

    public let secrets: CustomProviderSecretStoring
    private let storeURL: URL

    public init(
        storeURL: URL = CustomProviderStore.defaultStoreURL(),
        secrets: CustomProviderSecretStoring = CustomProviderKeychainSecretStore()
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
        return appSupport.appendingPathComponent("custom-providers.json")
    }

    public func allRecords() -> [CustomProviderRecord] { records }

    public func record(id: String) -> CustomProviderRecord? {
        records.first { $0.id == id }
    }

    public func enabledRecords() -> [CustomProviderRecord] {
        records.filter(\.isEnabled)
    }

    public func enabledWireSummaries() -> [CustomProviderWireSummary] {
        enabledRecords().map(wireSummary(for:))
    }

    public func wireSummary(for record: CustomProviderRecord) -> CustomProviderWireSummary {
        CustomProviderWireSummary(
            id: record.id,
            label: record.displayLabel,
            kind: record.kind,
            baseURL: record.baseURL,
            defaultModelId: record.defaultModelId,
            enabled: record.isEnabled,
            entries: record.models.map { model in
                ModelCatalogEntry(
                    id: model.id,
                    provider: record.kind == .anthropicCompatible ? .claude : .codex,
                    displayName: "\(record.displayLabel) · \(model.displayName ?? model.id)",
                    supportsThinking: false,
                    supportsEffort: false,
                    badge: "Custom",
                    customProviderId: record.id
                )
            }
        )
    }

    public func wireSummary(id: String) -> CustomProviderWireSummary? {
        record(id: id).map(wireSummary(for:))
    }

    public func chatProviderEntries() -> [CustomChatProviderEntry] {
        records.filter(\.isEnabled).map { record in
            let runtimeAvailable: Bool = {
                switch record.kind {
                case .anthropicCompatible:
                    return ShellRunner.locateBinary("claude") != nil
                case .openAICompatible:
                    return ShellRunner.locateBinary("codex") != nil
                }
            }()
            let keyAvailable = (try? resolveAPIKey(for: record)) != nil
            let available = runtimeAvailable && keyAvailable
            let reason: String? = {
                if !runtimeAvailable {
                    return record.kind == .anthropicCompatible
                        ? "claude CLI not on PATH"
                        : "codex CLI not on PATH"
                }
                if !keyAvailable {
                    switch record.keySource {
                    case .keychain:
                        return "API key not found in Keychain"
                    case .environmentVariable(let name):
                        return "Environment variable \(name) is not set in this process"
                    }
                }
                if record.lastTestResult?.success == false {
                    return record.lastTestResult?.errorDetail
                }
                return nil
            }()
            return CustomChatProviderEntry(
                id: record.id,
                label: record.displayLabel,
                kind: record.kind,
                available: available,
                reason: reason,
                lastProbedAt: record.lastTestResult?.testedAt
            )
        }
    }

    @discardableResult
    public func create(
        label: String?,
        kind: CustomProviderKind,
        baseURL rawBaseURL: String,
        keySource: CustomProviderKeySource,
        apiKey: String?,
        isEnabled: Bool = true,
        defaultModelId: String? = nil,
        models: [CustomProviderModel] = [],
        lastTestResult: CustomProviderTestOutcome? = nil
    ) throws -> CustomProviderRecord {
        let normalizedBase = try Self.normalizeBaseURL(rawBaseURL)
        let id = Self.mintId(from: normalizedBase, existingIds: Set(records.map(\.id)))
        let resolvedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let now = Date()
        var record = CustomProviderRecord(
            id: id,
            label: resolvedLabel,
            kind: kind,
            baseURL: normalizedBase,
            keySource: keySource,
            isEnabled: isEnabled,
            defaultModelId: defaultModelId,
            models: models,
            modelsFetchedAt: models.isEmpty ? nil : now,
            lastTestResult: lastTestResult,
            createdAt: now,
            updatedAt: now
        )
        if case .keychain = keySource {
            guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CustomProviderStoreError.keyUnavailable("API key is required for Keychain storage.")
            }
            guard secrets.write(apiKey, account: record.keychainAccount) else {
                throw CustomProviderStoreError.keychainWriteFailed
            }
        }
        records.append(record)
        save()
        return record
    }

    @discardableResult
    public func update(
        id: String,
        label: String?,
        kind: CustomProviderKind,
        baseURL rawBaseURL: String,
        keySource: CustomProviderKeySource,
        apiKey: String?,
        isEnabled: Bool,
        defaultModelId: String?,
        models: [CustomProviderModel]? = nil,
        modelsFetchedAt: Date? = nil,
        lastTestResult: CustomProviderTestOutcome? = nil
    ) throws -> CustomProviderRecord {
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw CustomProviderStoreError.providerNotFound(id)
        }
        let normalizedBase = try Self.normalizeBaseURL(rawBaseURL)
        let existing = records[idx]
        let resolvedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var next = existing
        next.label = resolvedLabel
        next.kind = kind
        next.baseURL = normalizedBase
        next.keySource = keySource
        next.isEnabled = isEnabled
        next.defaultModelId = defaultModelId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let models {
            next.models = models
            next.modelsFetchedAt = modelsFetchedAt ?? Date()
        }
        if let lastTestResult {
            next.lastTestResult = lastTestResult
        }
        next.updatedAt = Date()

        switch keySource {
        case .keychain:
            if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard secrets.write(apiKey, account: next.keychainAccount) else {
                    throw CustomProviderStoreError.keychainWriteFailed
                }
            } else if case .environmentVariable = existing.keySource {
                _ = secrets.delete(account: next.keychainAccount)
            }
        case .environmentVariable:
            _ = secrets.delete(account: next.keychainAccount)
        }

        records[idx] = next
        save()
        return next
    }

    public func delete(id: String) throws {
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw CustomProviderStoreError.providerNotFound(id)
        }
        let account = records[idx].keychainAccount
        guard secrets.delete(account: account) else {
            throw CustomProviderStoreError.keychainDeleteFailed
        }
        records.remove(at: idx)
        save()
    }

    public func setEnabled(id: String, isEnabled: Bool) throws {
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw CustomProviderStoreError.providerNotFound(id)
        }
        records[idx].isEnabled = isEnabled
        records[idx].updatedAt = Date()
        save()
    }

    public func setDefaultModel(id: String, modelId: String?) throws {
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw CustomProviderStoreError.providerNotFound(id)
        }
        records[idx].defaultModelId = modelId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        records[idx].updatedAt = Date()
        save()
    }

    public func setModels(id: String, models: [CustomProviderModel], fetchedAt: Date = Date()) throws {
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw CustomProviderStoreError.providerNotFound(id)
        }
        records[idx].models = models
        records[idx].modelsFetchedAt = fetchedAt
        if records[idx].defaultModelId == nil {
            records[idx].defaultModelId = models.first?.id
        }
        records[idx].updatedAt = Date()
        save()
    }

    public func setTestOutcome(id: String, outcome: CustomProviderTestOutcome) throws {
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw CustomProviderStoreError.providerNotFound(id)
        }
        records[idx].lastTestResult = outcome
        records[idx].updatedAt = Date()
        save()
    }

    /// Single key-resolution choke point. Never logs the secret value.
    public func resolveAPIKey(for record: CustomProviderRecord) throws -> String {
        switch record.keySource {
        case .keychain:
            guard let value = secrets.read(account: record.keychainAccount)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                throw CustomProviderStoreError.keyUnavailable("API key not found in Keychain.")
            }
            return value
        case .environmentVariable(let name):
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw CustomProviderStoreError.keyUnavailable("Environment variable name is empty.")
            }
            guard let value = ProcessInfo.processInfo.environment[trimmedName]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                throw CustomProviderStoreError.keyUnavailable("Environment variable \(trimmedName) is not set in this process.")
            }
            return value
        }
    }

    public func resolveAPIKey(id: String) throws -> String {
        guard let record = record(id: id) else {
            throw CustomProviderStoreError.providerNotFound(id)
        }
        return try resolveAPIKey(for: record)
    }

    // MARK: - URL + id helpers

    public static func normalizeBaseURL(_ raw: String) throws -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CustomProviderStoreError.invalidBaseURL(raw) }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            throw CustomProviderStoreError.invalidBaseURL(raw)
        }
        components.scheme = "https"
        components.fragment = nil
        components.query = nil
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        if path.lowercased().hasSuffix("/v1") {
            path = String(path.dropLast(3))
            while path.hasSuffix("/") {
                path.removeLast()
            }
        }
        components.path = path
        guard let url = components.url else {
            throw CustomProviderStoreError.invalidBaseURL(raw)
        }
        var normalized = url.absoluteString
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    public static func mintId(from baseURL: String, existingIds: Set<String>) -> String {
        let host = CustomProviderRecord.hostLabel(from: baseURL) ?? "provider"
        var slug = host.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        var candidate = String(slug)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        if candidate.isEmpty { candidate = "provider" }
        candidate = String(candidate.prefix(48))
        if reservedIds.contains(candidate) || existingIds.contains(candidate) {
            candidate = disambiguate(base: candidate, existingIds: existingIds)
        }
        return candidate
    }

    private static let reservedIds: Set<String> = {
        var ids = Set(ProviderRegistry.allProviderIDs)
        ids.formUnion(ProviderRegistry.allProviderIDs.map { ProviderRegistry.wireId(forCustomProviderId: $0) })
        ids.formUnion(ChatVendor.allCases.map(\.rawValue))
        ids.formUnion(["custom", "provider", "unknown", "openrouter", "antigravity", "chatgpt"])
        return ids
    }()

    private static func disambiguate(base: String, existingIds: Set<String>) -> String {
        var suffix = 2
        var candidate = "\(base)-\(suffix)"
        while reservedIds.contains(candidate) || existingIds.contains(candidate) {
            suffix += 1
            candidate = "\(base)-\(suffix)"
        }
        return candidate
    }

    // MARK: - Persistence

    private struct StoreFile: Codable {
        var schemaVersion: Int
        var records: [CustomProviderRecord]

        init(schemaVersion: Int = 1, records: [CustomProviderRecord]) {
            self.schemaVersion = schemaVersion
            self.records = records
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            records = try c.decodeIfPresent([CustomProviderRecord].self, forKey: .records) ?? []
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(StoreFile.self, from: Data(contentsOf: storeURL))
            records = file.records
        } catch {
            customProviderLogger.error("Failed to load custom providers: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        let file = StoreFile(records: records)
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
            customProviderLogger.error("Failed to save custom providers: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
