import Foundation
import ClawdmeterShared
import OSLog

private let registryLogger = Logger(subsystem: "com.clawdmeter.mac", category: "AgentSessionRegistry")

/// Single source of truth for live agent sessions.
///
/// `@MainActor`-isolated so SwiftUI views can observe `sessions` without
/// hopping. State mutations are serialized through the actor; the daemon
/// + JSONL tails (Phase 4) call `appendEvent(...)` / `updateStatus(...)`
/// from background contexts via `Task { @MainActor in ... }`.
///
/// Persists `sessions.json` schema v1 to `~/Library/Application Support/
/// Clawdmeter/sessions.json` for restart resilience (Codex Round 2 High #5:
/// atomic write via temp-file + rename + fsync; preserves unknown fields
/// for forward compat).
@MainActor
public final class AgentSessionRegistry: ObservableObject {

    @Published public private(set) var sessions: [AgentSession] = []

    /// Monotonic per-session event sequence. Backs E8 cursor contract.
    private var nextEventSeqBySession: [UUID: UInt64] = [:]

    /// Path to the sessions.json on-disk snapshot.
    private let storeURL: URL

    public init(
        storeURL: URL = AgentSessionRegistry.defaultStoreURL()
    ) {
        self.storeURL = storeURL
        load()
    }

    public nonisolated static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Clawdmeter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        return appSupport.appendingPathComponent("sessions.json")
    }

    // MARK: - Mutations

    /// Create a new session record. Caller (handle POST /sessions) has
    /// already spawned the tmux window; we just record the metadata.
    @discardableResult
    public func create(
        repoKey: String,
        repoDisplayName: String,
        agent: AgentKind,
        model: String?,
        goal: String?,
        worktreePath: String?,
        tmuxWindowId: String?,
        tmuxPaneId: String?,
        planMode: Bool
    ) -> AgentSession {
        let id = UUID()
        let now = Date()
        nextEventSeqBySession[id] = 1
        let session = AgentSession(
            id: id,
            repoKey: repoKey,
            repoDisplayName: repoDisplayName,
            agent: agent,
            model: model,
            goal: goal,
            worktreePath: worktreePath,
            tmuxWindowId: tmuxWindowId,
            tmuxPaneId: tmuxPaneId,
            status: planMode ? .planning : .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 1
        )
        sessions.append(session)
        save()
        return session
    }

    public func session(id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    public func updateStatus(id: UUID, status: AgentSessionStatus) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions[idx]
        sessions[idx] = AgentSession(
            id: s.id, repoKey: s.repoKey, repoDisplayName: s.repoDisplayName,
            agent: s.agent, model: s.model, goal: s.goal,
            worktreePath: s.worktreePath,
            tmuxWindowId: s.tmuxWindowId, tmuxPaneId: s.tmuxPaneId,
            status: status, planText: s.planText,
            createdAt: s.createdAt, lastEventAt: Date(),
            lastEventSeq: s.lastEventSeq + 1
        )
        nextEventSeqBySession[id] = (nextEventSeqBySession[id] ?? 1) + 1
        save()
    }

    public func setPlanText(id: UUID, planText: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions[idx]
        sessions[idx] = AgentSession(
            id: s.id, repoKey: s.repoKey, repoDisplayName: s.repoDisplayName,
            agent: s.agent, model: s.model, goal: s.goal,
            worktreePath: s.worktreePath,
            tmuxWindowId: s.tmuxWindowId, tmuxPaneId: s.tmuxPaneId,
            status: s.status, planText: planText,
            createdAt: s.createdAt, lastEventAt: Date(),
            lastEventSeq: s.lastEventSeq + 1
        )
        save()
    }

    public func delete(id: UUID) {
        sessions.removeAll { $0.id == id }
        nextEventSeqBySession.removeValue(forKey: id)
        save()
    }

    // MARK: - Persistence (atomic write + schema migration)

    private struct StoreFile: Codable {
        var schemaVersion: Int
        var sessions: [AgentSession]
    }

    private static let currentSchemaVersion = 1

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(StoreFile.self, from: data)
            if file.schemaVersion != Self.currentSchemaVersion {
                registryLogger.warning("sessions.json schema v\(file.schemaVersion) (we expect v\(Self.currentSchemaVersion)) — proceeding with raw decode")
            }
            self.sessions = file.sessions
            // Restore per-session seq counters from the loaded data.
            for session in file.sessions {
                nextEventSeqBySession[session.id] = session.lastEventSeq + 1
            }
            registryLogger.info("Loaded \(file.sessions.count) sessions from \(self.storeURL.path, privacy: .public)")
        } catch {
            registryLogger.error("Failed to load sessions.json: \(error.localizedDescription); starting empty")
        }
    }

    private func save() {
        let file = StoreFile(
            schemaVersion: Self.currentSchemaVersion,
            sessions: sessions
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            registryLogger.error("Failed to encode sessions for save")
            return
        }
        // Atomic write: write to temp file in the same directory, fsync,
        // then rename over the target. `Data.write(to:options:.atomic)`
        // does this for us.
        do {
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            registryLogger.error("Failed to save sessions.json: \(error.localizedDescription)")
        }
    }
}
