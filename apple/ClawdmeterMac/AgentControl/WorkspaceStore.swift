import Foundation
import CryptoKit
import ClawdmeterShared
import OSLog

private let workspaceStoreLogger = Logger(subsystem: "com.clawdmeter.mac", category: "WorkspaceStore")

/// Persisted Code V2 workspace registry. Lives alongside `sessions.json` at
/// `~/Library/Application Support/Clawdmeter/workspaces.json`. One
/// `CodeWorkspaceRecord` per canonical repo root; sessions reference
/// workspaces by id, and new sessions inherit the workspace's
/// `WorkspaceProviderDefaults` when their spawn request omits an explicit
/// model/effort/agent.
///
/// Migration semantics: the first time this store loads on a Mac that
/// already has a `sessions.json` but no `workspaces.json`, it walks the
/// existing sessions, groups by canonical repo root, and synthesizes one
/// workspace per repo seeded from the **newest** session's runtimeBinding.
/// Idempotent — once written, subsequent launches treat the on-disk file as
/// the source of truth and never re-migrate.
///
/// Mirrors `AgentSessionRegistry`'s atomic-write + version-tagged JSON
/// idiom (`schemaVersion`, `Data.write(options:.atomic)`, `.iso8601`).
@MainActor
public final class WorkspaceStore: ObservableObject {

    @Published public private(set) var workspaces: [CodeWorkspaceRecord] = []

    private let storeURL: URL
    private let sessionsURL: URL

    public init(
        storeURL: URL = WorkspaceStore.defaultStoreURL(),
        sessionsURL: URL = AgentSessionRegistry.defaultStoreURL()
    ) {
        self.storeURL = storeURL
        self.sessionsURL = sessionsURL
        load()
        migrateFromSessionsIfNeeded()
        // Drop cards for repos that no longer exist on disk (throwaway/QA
        // clones deleted out from under us) so the sidebar doesn't show stale
        // duplicates of the same project.
        _ = pruneOrphanedWorkspaces()
    }

    public nonisolated static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Clawdmeter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: appSupport, withIntermediateDirectories: true
        )
        return appSupport.appendingPathComponent("workspaces.json")
    }

    // MARK: - Public API

    public func all() -> [CodeWorkspaceRecord] { workspaces }

    public func workspace(forRepoRoot repoRoot: String) -> CodeWorkspaceRecord? {
        workspaces.first { $0.repoRoot == repoRoot }
    }

    public func workspace(id: UUID) -> CodeWorkspaceRecord? {
        workspaces.first { $0.id == id }
    }

    /// Insert-or-replace by id. Used by the migration path and by callers
    /// that want full record control (tests, future workspace-management UI).
    @discardableResult
    public func upsert(_ record: CodeWorkspaceRecord) -> CodeWorkspaceRecord {
        if let idx = workspaces.firstIndex(where: { $0.id == record.id }) {
            var copy = record
            // Always bump updatedAt on upsert so callers don't have to
            // remember.
            copy = CodeWorkspaceRecord(
                id: record.id,
                projectId: record.projectId,
                repoRoot: record.repoRoot,
                repoDisplayName: record.repoDisplayName,
                defaultBranch: record.defaultBranch,
                worktreeRoot: record.worktreeRoot,
                runtimeCwd: record.runtimeCwd,
                chatCwd: record.chatCwd,
                providerDefaults: record.providerDefaults,
                filesToCopy: record.filesToCopy,
                activeSessionIds: record.activeSessionIds,
                branchName: record.branchName,
                prMirrorState: record.prMirrorState,
                archiveMetadata: record.archiveMetadata,
                createdAt: workspaces[idx].createdAt,
                updatedAt: Date()
            )
            workspaces[idx] = copy
            save()
            return copy
        } else {
            workspaces.append(record)
            save()
            return record
        }
    }

    /// Remove a workspace record by id ("Remove from list" in the sidebar).
    /// Forgets the managed-workspace card only — it does NOT delete the repo
    /// on disk or archive its sessions. Returns true if a record was removed.
    @discardableResult
    public func delete(id: UUID) -> Bool {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return false }
        workspaces.remove(at: idx)
        save()
        return true
    }

    /// Drop workspace records whose `repoRoot` directory no longer exists on
    /// disk. These accrue from throwaway/QA clones deleted without the app
    /// being told, and otherwise linger forever as stale cards (the same
    /// project showing up multiple times). Called once on launch. Returns the
    /// number pruned.
    @discardableResult
    public func pruneOrphanedWorkspaces() -> Int {
        let survivors = workspaces.filter { rec in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: rec.repoRoot, isDirectory: &isDir) && isDir.boolValue
        }
        let pruned = workspaces.count - survivors.count
        if pruned > 0 {
            workspaceStoreLogger.info("Pruned \(pruned) orphaned workspace(s) with a missing repoRoot")
            workspaces = survivors
            save()
        }
        return pruned
    }

    /// Updates only the provider defaults for an existing workspace.
    /// Returns the updated record, or nil if no workspace matches `id`.
    @discardableResult
    public func setProviderDefaults(
        id: UUID,
        defaults: WorkspaceProviderDefaults
    ) -> CodeWorkspaceRecord? {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return nil }
        let existing = workspaces[idx]
        let updated = CodeWorkspaceRecord(
            id: existing.id,
            projectId: existing.projectId,
            repoRoot: existing.repoRoot,
            repoDisplayName: existing.repoDisplayName,
            defaultBranch: existing.defaultBranch,
            worktreeRoot: existing.worktreeRoot,
            runtimeCwd: existing.runtimeCwd,
            chatCwd: existing.chatCwd,
            providerDefaults: defaults,
            filesToCopy: existing.filesToCopy,
            activeSessionIds: existing.activeSessionIds,
            branchName: existing.branchName,
            prMirrorState: existing.prMirrorState,
            archiveMetadata: existing.archiveMetadata,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
        workspaces[idx] = updated
        save()
        return updated
    }

    /// Partially updates workspace defaults. Omitted fields are preserved.
    @discardableResult
    public func updateDefaults(
        id: UUID,
        providerDefaults: WorkspaceProviderDefaults? = nil,
        filesToCopy: WorkspaceFilesToCopySettings? = nil
    ) -> CodeWorkspaceRecord? {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { return nil }
        let existing = workspaces[idx]
        let updated = CodeWorkspaceRecord(
            id: existing.id,
            projectId: existing.projectId,
            repoRoot: existing.repoRoot,
            repoDisplayName: existing.repoDisplayName,
            defaultBranch: existing.defaultBranch,
            worktreeRoot: existing.worktreeRoot,
            runtimeCwd: existing.runtimeCwd,
            chatCwd: existing.chatCwd,
            providerDefaults: providerDefaults ?? existing.providerDefaults,
            filesToCopy: filesToCopy ?? existing.filesToCopy,
            activeSessionIds: existing.activeSessionIds,
            branchName: existing.branchName,
            prMirrorState: existing.prMirrorState,
            archiveMetadata: existing.archiveMetadata,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
        workspaces[idx] = updated
        save()
        return updated
    }

    /// Records archive metadata (final status, winner, summary) on the
    /// workspace identified by `repoRoot`. No-op when no workspace exists.
    @discardableResult
    public func recordArchive(
        repoRoot: String,
        metadata: WorkspaceArchiveMetadata
    ) -> CodeWorkspaceRecord? {
        guard let idx = workspaces.firstIndex(where: { $0.repoRoot == repoRoot }) else { return nil }
        let existing = workspaces[idx]
        let updated = CodeWorkspaceRecord(
            id: existing.id,
            projectId: existing.projectId,
            repoRoot: existing.repoRoot,
            repoDisplayName: existing.repoDisplayName,
            defaultBranch: existing.defaultBranch,
            worktreeRoot: existing.worktreeRoot,
            runtimeCwd: existing.runtimeCwd,
            chatCwd: existing.chatCwd,
            providerDefaults: existing.providerDefaults,
            filesToCopy: existing.filesToCopy,
            activeSessionIds: existing.activeSessionIds,
            branchName: existing.branchName,
            prMirrorState: existing.prMirrorState,
            archiveMetadata: metadata,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
        workspaces[idx] = updated
        save()
        return updated
    }

    /// Replaces `activeSessionIds` on the workspace covering `repoRoot`,
    /// creating a minimal workspace if none exists. Called by
    /// `AgentSessionRegistry` when sessions are spawned / archived so the
    /// workspace reflects current liveness.
    public func syncActiveSessions(repoRoot: String, sessionIds: [UUID]) {
        guard !repoRoot.isEmpty, repoRoot != "(unknown)" else { return }
        if let idx = workspaces.firstIndex(where: { $0.repoRoot == repoRoot }) {
            let existing = workspaces[idx]
            if existing.activeSessionIds == sessionIds { return }
            let updated = CodeWorkspaceRecord(
                id: existing.id,
                projectId: existing.projectId,
                repoRoot: existing.repoRoot,
                repoDisplayName: existing.repoDisplayName,
                defaultBranch: existing.defaultBranch,
                worktreeRoot: existing.worktreeRoot,
                runtimeCwd: existing.runtimeCwd,
                chatCwd: existing.chatCwd,
                providerDefaults: existing.providerDefaults,
                filesToCopy: existing.filesToCopy,
                activeSessionIds: sessionIds,
                branchName: existing.branchName,
                prMirrorState: existing.prMirrorState,
                archiveMetadata: existing.archiveMetadata,
                createdAt: existing.createdAt,
                updatedAt: Date()
            )
            workspaces[idx] = updated
            save()
        } else {
            // No workspace yet — synthesize a minimal one keyed by the
            // canonical repo root. Callers that need a richer initial record
            // should use `upsert(_:)`.
            let projectId = Self.deterministicUUID(for: "project:\(repoRoot)")
            let id = Self.deterministicUUID(for: "workspace:\(repoRoot)")
            let record = CodeWorkspaceRecord(
                id: id,
                projectId: projectId,
                repoRoot: repoRoot,
                repoDisplayName: Self.displayName(forRepoRoot: repoRoot),
                runtimeCwd: repoRoot,
                providerDefaults: WorkspaceProviderDefaults(),
                filesToCopy: WorkspaceFilesToCopySettings(),
                activeSessionIds: sessionIds
            )
            workspaces.append(record)
            save()
        }
    }

    // MARK: - Migration

    /// One-shot migration: if `workspaces.json` does not yet exist on disk,
    /// reconstruct one workspace per canonical repo root from the existing
    /// `sessions.json`. Once `workspaces.json` is written, this is a no-op
    /// on every subsequent launch.
    private func migrateFromSessionsIfNeeded() {
        guard workspaces.isEmpty else { return }
        guard !FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard FileManager.default.fileExists(atPath: sessionsURL.path) else {
            workspaceStoreLogger.info("No sessions.json — skipping workspace migration")
            return
        }
        guard let data = try? Data(contentsOf: sessionsURL) else { return }
        struct StoreFile: Decodable { let sessions: [AgentSession] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(StoreFile.self, from: data) else {
            workspaceStoreLogger.warning("sessions.json present but failed to decode; skipping migration")
            return
        }
        // Group by repoKey (canonical normalized cwd). Chat sessions with
        // nil repoKey are skipped — they don't belong to any workspace.
        var byRoot: [String: [AgentSession]] = [:]
        for s in file.sessions {
            guard let root = s.repoKey, !root.isEmpty, root != "(unknown)" else { continue }
            byRoot[root, default: []].append(s)
        }
        guard !byRoot.isEmpty else {
            workspaceStoreLogger.info("Migration found 0 sessions with a repoKey; writing empty workspaces.json")
            save()
            return
        }
        var created: [CodeWorkspaceRecord] = []
        for (root, sessions) in byRoot {
            // Newest session by createdAt drives provider defaults +
            // workspace-level runtimeCwd / worktreeRoot.
            let newest = sessions.max { $0.createdAt < $1.createdAt } ?? sessions[0]
            let runtimeCwd = newest.runtimeCwd ?? newest.worktreePath ?? root
            let chatCwd = newest.chatCwd
            let worktreeRoot = newest.worktreePath
            let providerDefaults = WorkspaceProviderDefaults(
                defaultAgent: newest.agent,
                defaultModelByProvider: Self.modelMapSeed(from: newest),
                defaultRuntimeByProvider: Self.runtimeMapSeed(from: newest),
                defaultEffort: newest.effort
            )
            let activeIds = sessions
                .filter { $0.status == .running || $0.status == .planning }
                .map(\.id)
            let projectId = Self.deterministicUUID(for: "project:\(root)")
            let id = Self.deterministicUUID(for: "workspace:\(root)")
            let displayName = sessions
                .compactMap { $0.repoDisplayName.isEmpty ? nil : $0.repoDisplayName }
                .first ?? Self.displayName(forRepoRoot: root)
            let record = CodeWorkspaceRecord(
                id: id,
                projectId: projectId,
                repoRoot: root,
                repoDisplayName: displayName,
                defaultBranch: nil,
                worktreeRoot: worktreeRoot,
                runtimeCwd: runtimeCwd,
                chatCwd: chatCwd,
                providerDefaults: providerDefaults,
                filesToCopy: WorkspaceFilesToCopySettings(),
                activeSessionIds: activeIds,
                branchName: nil,
                prMirrorState: newest.prMirrorState,
                archiveMetadata: nil,
                createdAt: sessions.map(\.createdAt).min() ?? Date(),
                updatedAt: Date()
            )
            created.append(record)
        }
        workspaces = created
        save()
        workspaceStoreLogger.info("Migrated \(created.count) workspaces from sessions.json")
    }

    private static func modelMapSeed(from session: AgentSession) -> [String: String] {
        guard let model = session.model, !model.isEmpty else { return [:] }
        // Key on the agent kind so the next session in the same provider
        // family inherits the model. Cross-provider defaults stay empty
        // until the user actually uses a second provider in this repo.
        return [session.agent.rawValue: model]
    }

    private static func runtimeMapSeed(from session: AgentSession) -> [String: SessionRuntimeKind] {
        guard let binding = session.runtimeBinding else { return [:] }
        return [session.agent.rawValue: binding.runtimeKind]
    }

    // MARK: - Helpers

    /// Friendly display name from a canonical repo root. Last path
    /// component for ordinary git repos; falls back to the full path
    /// for unusual layouts (root, single-segment, etc.).
    static func displayName(forRepoRoot repoRoot: String) -> String {
        let last = (repoRoot as NSString).lastPathComponent
        return last.isEmpty ? repoRoot : last
    }

    /// Deterministic UUID derived from an arbitrary stable string. Same
    /// input → same UUID across launches, so the workspace id stays
    /// pinned to its repo root without needing a separate id table.
    /// Uses SHA-256 instead of MD5 so the future "namespace UUID v5"
    /// migration is a no-op (UUID v5 uses SHA-1, but we don't need RFC
    /// conformance — we just need stability and collision resistance).
    static func deterministicUUID(for input: String) -> UUID {
        let digest = SHA256.hash(data: Data(input.utf8))
        var bytes = Array(digest).prefix(16)
        // Set version (4) + variant (RFC 4122) bits so the result is a
        // valid v4-shaped UUID. Pure hash bytes would still be a UUID
        // technically, but Apple frameworks sometimes assert on the
        // version nibble.
        bytes[6] = (bytes[6] & 0x0F) | 0x40 // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // variant 10
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return uuid
    }

    // MARK: - Persistence

    private struct StoreFile: Codable {
        var schemaVersion: Int
        var workspaces: [CodeWorkspaceRecord]
    }

    /// v1 (Code V2 deferred follow-ups ship, 2026-05-23): initial schema.
    /// One `CodeWorkspaceRecord` per canonical repo root.
    private static let currentSchemaVersion = 1

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(StoreFile.self, from: data)
            if file.schemaVersion != Self.currentSchemaVersion {
                workspaceStoreLogger.warning("workspaces.json schema v\(file.schemaVersion) (we expect v\(Self.currentSchemaVersion)) — proceeding with raw decode")
            }
            self.workspaces = file.workspaces
            workspaceStoreLogger.info("Loaded \(file.workspaces.count) workspaces from \(self.storeURL.path, privacy: .public)")
        } catch {
            workspaceStoreLogger.error("Failed to load workspaces.json: \(error.localizedDescription); starting empty")
        }
    }

    private func save() {
        let file = StoreFile(
            schemaVersion: Self.currentSchemaVersion,
            workspaces: workspaces
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else {
            workspaceStoreLogger.error("Failed to encode workspaces for save")
            return
        }
        do {
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            workspaceStoreLogger.error("Failed to save workspaces.json: \(error.localizedDescription)")
        }
    }
}
