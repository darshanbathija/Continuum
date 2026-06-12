import Foundation

/// Persists registered execution hosts for multi-device R1.
///
/// File: `~/Library/Application Support/Clawdmeter/execution-hosts.json`
public final class ExecutionHostStore: @unchecked Sendable {

    public static let shared = ExecutionHostStore()

    private static let currentSchemaVersion = 1
    private static let defaultLocalDisplayName = "My Mac"

    private let lock = NSLock()
    private let fileURL: URL
    private var localHostId: UUID
    private var hostsById: [UUID: ExecutionHost]

    public init(fileURL: URL? = nil) {
        let resolvedURL: URL
        if let fileURL {
            resolvedURL = fileURL
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("Clawdmeter", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            resolvedURL = dir.appendingPathComponent("execution-hosts.json", isDirectory: false)
        }
        self.fileURL = resolvedURL
        if let loaded = Self.load(from: resolvedURL) {
            self.localHostId = loaded.localHostId
            self.hostsById = loaded.hostsById
        } else {
            let id = UUID()
            self.localHostId = id
            self.hostsById = [
                id: ExecutionHost(
                    id: id,
                    displayName: Self.defaultLocalDisplayName,
                    kind: .localMac,
                    primaryTransport: .relay,
                    preferredTransports: [.relay, .lanDirect],
                    health: .healthy,
                    daemonWireVersion: AgentControlWireVersion.current
                ),
            ]
            self.persistLocked()
        }
    }

    // MARK: - Read

    public func localHost() -> ExecutionHost {
        lock.lock()
        defer { lock.unlock() }
        return hostsById[localHostId] ?? Self.fallbackLocalHost(id: localHostId)
    }

    public func localHostIdValue() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return localHostId
    }

    public func allHosts() -> [ExecutionHost] {
        lock.lock()
        defer { lock.unlock() }
        return hostsById.values.sorted { lhs, rhs in
            if lhs.id == localHostId { return true }
            if rhs.id == localHostId { return false }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    public func host(id: UUID) -> ExecutionHost? {
        lock.lock()
        defer { lock.unlock() }
        return hostsById[id]
    }

    // MARK: - Write

    @discardableResult
    public func upsert(_ host: ExecutionHost) -> ExecutionHost {
        lock.lock()
        defer { lock.unlock() }
        hostsById[host.id] = host
        persistLocked()
        return host
    }

    public func remove(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard id != localHostId else { return false }
        guard hostsById.removeValue(forKey: id) != nil else { return false }
        persistLocked()
        return true
    }

    /// Ensures the local Mac host row exists and reflects current wire version.
    public func refreshLocalHostMetadata() {
        lock.lock()
        defer { lock.unlock() }
        var local = hostsById[localHostId] ?? Self.fallbackLocalHost(id: localHostId)
        local.health = .healthy
        local.daemonWireVersion = AgentControlWireVersion.current
        hostsById[localHostId] = local
        persistLocked()
    }

    // MARK: - Persistence

    private struct PersistedFile: Codable {
        let schemaVersion: Int
        let localHostId: UUID
        let hosts: [ExecutionHost]
    }

    private static func load(from url: URL) -> (localHostId: UUID, hostsById: [UUID: ExecutionHost])? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersistedFile.self, from: data),
              !decoded.hosts.isEmpty
        else { return nil }
        let map = Dictionary(uniqueKeysWithValues: decoded.hosts.map { ($0.id, $0) })
        guard map[decoded.localHostId] != nil else { return nil }
        return (decoded.localHostId, map)
    }

    private func persistLocked() {
        let payload = PersistedFile(
            schemaVersion: Self.currentSchemaVersion,
            localHostId: localHostId,
            hosts: hostsById.values.sorted { $0.displayName < $1.displayName }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private static func fallbackLocalHost(id: UUID) -> ExecutionHost {
        ExecutionHost(
            id: id,
            displayName: defaultLocalDisplayName,
            kind: .localMac,
            primaryTransport: .relay,
            preferredTransports: [.relay, .lanDirect],
            health: .healthy,
            daemonWireVersion: AgentControlWireVersion.current
        )
    }
}
