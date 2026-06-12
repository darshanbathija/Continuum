import Foundation

/// One billable run segment for a session on an execution host (R1 1E).
public struct HostRunRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let sessionId: UUID
    public let executionHostId: UUID
    public let executionHostLabel: String
    public let cloudProvider: String?
    public let startedAt: Date
    public var stoppedAt: Date?
    public var billableMinutes: Int

    public init(
        id: UUID = UUID(),
        sessionId: UUID,
        executionHostId: UUID,
        executionHostLabel: String,
        cloudProvider: String? = nil,
        startedAt: Date = Date(),
        stoppedAt: Date? = nil,
        billableMinutes: Int = 0
    ) {
        self.id = id
        self.sessionId = sessionId
        self.executionHostId = executionHostId
        self.executionHostLabel = executionHostLabel
        self.cloudProvider = cloudProvider
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.billableMinutes = billableMinutes
    }
}

public struct HostRunMinuteSummary: Codable, Hashable, Sendable, Identifiable {
    public let executionHostId: UUID
    public let executionHostLabel: String
    public let cloudProvider: String?
    public let billableMinutes: Int
    public let activeSessionCount: Int

    public var id: UUID { executionHostId }

    public init(
        executionHostId: UUID,
        executionHostLabel: String,
        cloudProvider: String? = nil,
        billableMinutes: Int,
        activeSessionCount: Int
    ) {
        self.executionHostId = executionHostId
        self.executionHostLabel = executionHostLabel
        self.cloudProvider = cloudProvider
        self.billableMinutes = billableMinutes
        self.activeSessionCount = activeSessionCount
    }
}

public struct HostRunMinutesResponse: Codable, Sendable {
    public let hosts: [HostRunMinuteSummary]
    public let records: [HostRunRecord]

    public init(hosts: [HostRunMinuteSummary], records: [HostRunRecord]) {
        self.hosts = hosts
        self.records = records
    }

    /// Billable minutes for a session (open segments use the latest record).
    public func billableMinutes(forSession sessionId: UUID) -> Int? {
        let matching = records.filter { $0.sessionId == sessionId }
        guard !matching.isEmpty else { return nil }
        return matching.map(\.billableMinutes).max()
    }
}

/// Persists active + completed host run segments for analytics (R1 1E).
public final class HostRunMinuteStore: @unchecked Sendable {

    public static let shared = HostRunMinuteStore()

    private let lock = NSLock()
    private let fileURL: URL
    private var openBySession: [UUID: HostRunRecord] = [:]
    private var completed: [HostRunRecord] = []

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("Clawdmeter", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("host-run-minutes.json", isDirectory: false)
        }
        loadLocked()
    }

    public func sessionStarted(_ session: AgentSession, at date: Date = Date()) {
        guard let hostId = session.executionHostId else { return }
        let cloudProvider = ExecutionHostStore.shared.host(id: hostId)?.cloudProvider
        lock.lock()
        defer { lock.unlock() }
        guard openBySession[session.id] == nil else { return }
        openBySession[session.id] = HostRunRecord(
            sessionId: session.id,
            executionHostId: hostId,
            executionHostLabel: session.executionHostLabel ?? "Unknown host",
            cloudProvider: cloudProvider,
            startedAt: date
        )
        persistLocked()
    }

    public func sessionStopped(_ sessionId: UUID, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard var open = openBySession.removeValue(forKey: sessionId) else { return }
        open.stoppedAt = date
        open.billableMinutes = Self.minutes(from: open.startedAt, to: date)
        completed.append(open)
        persistLocked()
    }

    public func tickOpenSessions(activeSessionIds: Set<UUID>, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for (sessionId, var record) in openBySession {
            if activeSessionIds.contains(sessionId) {
                let mins = Self.minutes(from: record.startedAt, to: now)
                if mins != record.billableMinutes {
                    record.billableMinutes = mins
                    openBySession[sessionId] = record
                    changed = true
                }
            } else {
                openBySession.removeValue(forKey: sessionId)
                record.stoppedAt = now
                record.billableMinutes = Self.minutes(from: record.startedAt, to: now)
                completed.append(record)
                changed = true
            }
        }
        if changed { persistLocked() }
    }

    public func summaries(activeCountsByHost: [UUID: Int]) -> [HostRunMinuteSummary] {
        lock.lock()
        defer { lock.unlock() }
        var minutesByHost: [UUID: (label: String, minutes: Int, cloud: String?)] = [:]
        for record in completed + openBySession.values {
            var entry = minutesByHost[record.executionHostId]
                ?? (record.executionHostLabel, 0, record.cloudProvider)
            entry.minutes += record.billableMinutes
            minutesByHost[record.executionHostId] = entry
        }
        return minutesByHost.map { hostId, value in
            HostRunMinuteSummary(
                executionHostId: hostId,
                executionHostLabel: value.label,
                cloudProvider: value.cloud,
                billableMinutes: value.minutes,
                activeSessionCount: activeCountsByHost[hostId] ?? 0
            )
        }
        .sorted { $0.executionHostLabel.localizedCaseInsensitiveCompare($1.executionHostLabel) == .orderedAscending }
    }

    public func allRecords() -> [HostRunRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(completed) + Array(openBySession.values)
    }

    /// Billable minutes for a session (open segments tick to `now`).
    public func billableMinutes(forSession sessionId: UUID, now: Date = Date()) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if let open = openBySession[sessionId] {
            return Self.minutes(from: open.startedAt, to: now)
        }
        let closed = completed.filter { $0.sessionId == sessionId }
        guard !closed.isEmpty else { return nil }
        return closed.map(\.billableMinutes).max()
    }

    private struct Persisted: Codable {
        var open: [HostRunRecord]
        var completed: [HostRunRecord]
    }

    private static func minutes(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) / 60.0))
    }

    private func loadLocked() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data)
        else { return }
        completed = decoded.completed
        openBySession = Dictionary(uniqueKeysWithValues: decoded.open.map { ($0.sessionId, $0) })
    }

    private func persistLocked() {
        let payload = Persisted(open: Array(openBySession.values), completed: completed)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
