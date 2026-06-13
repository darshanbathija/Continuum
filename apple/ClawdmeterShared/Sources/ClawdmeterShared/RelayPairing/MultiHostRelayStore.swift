import Foundation
#if canImport(Security)
import Security
#endif

/// Per-execution-host relay pairing records (D16).
///
/// Separate from `RelayPairingStore` which holds the primary Mac↔iPhone
/// pairing only. Secrets live in Keychain; JSON holds wire metadata.
public final class MultiHostRelayStore: @unchecked Sendable {

    public static let shared = MultiHostRelayStore()

    public struct Record: Codable, Hashable, Sendable, Identifiable {
        public let hostId: UUID
        public let sid: String
        public let relayUrl: String
        public let pairedAt: Date

        public var id: UUID { hostId }

        public init(hostId: UUID, sid: String, relayUrl: String, pairedAt: Date = Date()) {
            self.hostId = hostId
            self.sid = sid
            self.relayUrl = relayUrl
            self.pairedAt = pairedAt
        }
    }

    private struct Secrets: Codable {
        let iosTok: String
        let derivedSymmetricKeyBase64URL: String?
    }

    private let lock = NSLock()
    private let fileURL: URL
#if canImport(Security)
    private let keychainService: String
#endif

    public init(
        fileURL: URL? = nil,
        keychainService: String = "com.clawdmeter.relay.execution-host"
    ) {
        let resolvedURL: URL
        if let fileURL {
            resolvedURL = fileURL
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("Clawdmeter", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            resolvedURL = dir.appendingPathComponent("execution-relay-pairings.json", isDirectory: false)
        }
        self.fileURL = resolvedURL
#if canImport(Security)
        self.keychainService = keychainService
#endif
    }

    public func record(for hostId: UUID) -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return loadRecordsLocked()[hostId]
    }

    public func allRecords() -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return Array(loadRecordsLocked().values)
    }

    public func save(
        record: Record,
        iosToken: String,
        derivedSymmetricKeyBase64URL: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        var map = loadRecordsLocked()
        map[record.hostId] = record
        persistRecordsLocked(map)
        persistSecretsLocked(
            hostId: record.hostId,
            secrets: Secrets(iosTok: iosToken, derivedSymmetricKeyBase64URL: derivedSymmetricKeyBase64URL)
        )
    }

    public func remove(hostId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var map = loadRecordsLocked()
        map.removeValue(forKey: hostId)
        persistRecordsLocked(map)
        deleteSecretsLocked(hostId: hostId)
    }

    public func iosToken(for hostId: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return readSecretsLocked(hostId: hostId)?.iosTok
    }

    public func derivedSymmetricKeyBase64URL(for hostId: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return readSecretsLocked(hostId: hostId)?.derivedSymmetricKeyBase64URL
    }

    // MARK: - File IO

    private func loadRecordsLocked() -> [UUID: Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Record].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.hostId, $0) })
    }

    private func persistRecordsLocked(_ map: [UUID: Record]) {
        let list = map.values.sorted { $0.pairedAt < $1.pairedAt }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

#if canImport(Security)
    private func keychainAccount(for hostId: UUID) -> String {
        "execution-host-\(hostId.uuidString)"
    }

    private func persistSecretsLocked(hostId: UUID, secrets: Secrets) {
        guard let blob = try? JSONEncoder().encode(secrets) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount(for: hostId),
            kSecValueData as String: blob,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func readSecretsLocked(hostId: UUID) -> Secrets? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount(for: hostId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let secrets = try? JSONDecoder().decode(Secrets.self, from: data)
        else { return nil }
        return secrets
    }

    private func deleteSecretsLocked(hostId: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount(for: hostId),
        ]
        SecItemDelete(query as CFDictionary)
    }
#else
    private func persistSecretsLocked(hostId: UUID, secrets: Secrets) {}
    private func readSecretsLocked(hostId: UUID) -> Secrets? { nil }
    private func deleteSecretsLocked(hostId: UUID) {}
#endif
}
