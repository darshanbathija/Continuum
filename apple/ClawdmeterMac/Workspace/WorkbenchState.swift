import Foundation
import Combine
import ClawdmeterShared

enum WorkbenchPaneTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case plan = "Plan"
    case diff = "Diff"
    case sources = "Sources"
    case artifacts = "Artifacts"
    case browser = "Browser"
    case pr = "PR"
    case terminal = "Terminal"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .plan
    }

    var systemImage: String {
        switch self {
        case .plan:      return "list.bullet.rectangle"
        case .diff:      return "arrow.triangle.swap"
        case .sources:   return "doc.text.magnifyingglass"
        case .artifacts: return "paperclip"
        case .browser:   return "safari"
        case .pr:        return "arrow.triangle.pull"
        case .terminal:  return "terminal"
        }
    }
}

struct QueuedWorkbenchSend: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let sessionId: UUID
    var text: String
    var attachmentPaths: [String]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        text: String,
        attachmentPaths: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.attachmentPaths = attachmentPaths
        self.createdAt = createdAt
    }
}

enum QueuedPromptRenderer {
    static func render(text: String, attachmentPaths: [URL]) -> String {
        var lines: [String] = attachmentPaths.map { "@\($0.path)" }
        let prose = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prose.isEmpty {
            lines.append(prose)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct RunProfileStateSnapshot: Codable, Equatable, Sendable {
    var profileId: UUID
    var sessionId: UUID?
    var cwd: String?
    var command: String?
    var detectedURL: String?
    var status: String

    init(
        profileId: UUID = UUID(),
        sessionId: UUID? = nil,
        cwd: String? = nil,
        command: String? = nil,
        detectedURL: String? = nil,
        status: String = "idle"
    ) {
        self.profileId = profileId
        self.sessionId = sessionId
        self.cwd = cwd
        self.command = command
        self.detectedURL = detectedURL
        self.status = status
    }
}

struct PRCacheStateSnapshot: Codable, Equatable, Sendable {
    var sessionId: UUID
    var prURL: String?
    var state: String?
    var checksConclusion: String?
    var updatedAt: Date

    init(
        sessionId: UUID,
        prURL: String? = nil,
        state: String? = nil,
        checksConclusion: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.prURL = prURL
        self.state = state
        self.checksConclusion = checksConclusion
        self.updatedAt = updatedAt
    }
}

struct CheckpointStateSnapshot: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var sessionId: UUID
    var refName: String
    var turnId: String?
    var createdAt: Date
    var summary: String?

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        refName: String,
        turnId: String? = nil,
        createdAt: Date = Date(),
        summary: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.refName = refName
        self.turnId = turnId
        self.createdAt = createdAt
        self.summary = summary
    }
}

struct CheckpointRestorePlan: Equatable, Identifiable, Sendable {
    var id = UUID()
    var target: CheckpointStateSnapshot
    var safety: CheckpointStateSnapshot
    var diffStat: String
    var diffPatch: String
    var patchTruncated: Bool
    var dirtyStatusLines: [String]
    var untrackedOverwritePaths: [String]
    var untrackedSnapshotPaths: [String]
    var blockingReasons: [String]

    var isBlocked: Bool { !blockingReasons.isEmpty }
}

struct WorkbenchRefreshState: Codable, Equatable, Sendable {
    var generation: Int
    var startedAt: Date?
    var completedAt: Date?

    init(generation: Int = 0, startedAt: Date? = nil, completedAt: Date? = nil) {
        self.generation = generation
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

struct WorkbenchStateSnapshot: Codable, Equatable, Sendable {
    var selectedSessionId: UUID?
    var selectedRightPane: WorkbenchPaneTab
    var showingReviewPane: Bool
    var density: TranscriptDensity
    var workspaceWidth: Double
    var sidebarWidth: Double?
    var centerWidth: Double?
    var reviewWidth: Double?
    var selectedRightPaneBySession: [UUID: WorkbenchPaneTab]
    var queuedSends: [QueuedWorkbenchSend]
    var runProfiles: [UUID: RunProfileStateSnapshot]
    var prCache: [UUID: PRCacheStateSnapshot]
    var checkpoints: [UUID: [CheckpointStateSnapshot]]
    var refresh: WorkbenchRefreshState
    var updatedAt: Date

    init(
        selectedSessionId: UUID? = nil,
        selectedRightPane: WorkbenchPaneTab = .plan,
        showingReviewPane: Bool = true,
        density: TranscriptDensity = .balanced,
        workspaceWidth: Double = 1400,
        sidebarWidth: Double? = nil,
        centerWidth: Double? = nil,
        reviewWidth: Double? = nil,
        selectedRightPaneBySession: [UUID: WorkbenchPaneTab] = [:],
        queuedSends: [QueuedWorkbenchSend] = [],
        runProfiles: [UUID: RunProfileStateSnapshot] = [:],
        prCache: [UUID: PRCacheStateSnapshot] = [:],
        checkpoints: [UUID: [CheckpointStateSnapshot]] = [:],
        refresh: WorkbenchRefreshState = WorkbenchRefreshState(),
        updatedAt: Date = Date()
    ) {
        self.selectedSessionId = selectedSessionId
        self.selectedRightPane = selectedRightPane
        self.showingReviewPane = showingReviewPane
        self.density = density
        self.workspaceWidth = workspaceWidth
        self.sidebarWidth = sidebarWidth
        self.centerWidth = centerWidth
        self.reviewWidth = reviewWidth
        self.selectedRightPaneBySession = selectedRightPaneBySession
        self.queuedSends = queuedSends
        self.runProfiles = runProfiles
        self.prCache = prCache
        self.checkpoints = checkpoints
        self.refresh = refresh
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case selectedSessionId, selectedRightPane, showingReviewPane, density
        case workspaceWidth, sidebarWidth, centerWidth, reviewWidth
        case selectedRightPaneBySession, queuedSends, runProfiles, prCache, checkpoints, refresh, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedSessionId = try c.decodeIfPresent(UUID.self, forKey: .selectedSessionId)
        selectedRightPane = try c.decodeIfPresent(WorkbenchPaneTab.self, forKey: .selectedRightPane) ?? .plan
        showingReviewPane = try c.decodeIfPresent(Bool.self, forKey: .showingReviewPane) ?? true
        density = try c.decodeIfPresent(TranscriptDensity.self, forKey: .density) ?? .balanced
        workspaceWidth = try c.decodeIfPresent(Double.self, forKey: .workspaceWidth) ?? 1400
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth)
        centerWidth = try c.decodeIfPresent(Double.self, forKey: .centerWidth)
        reviewWidth = try c.decodeIfPresent(Double.self, forKey: .reviewWidth)
        selectedRightPaneBySession = try c.decodeIfPresent([UUID: WorkbenchPaneTab].self, forKey: .selectedRightPaneBySession) ?? [:]
        queuedSends = try c.decodeIfPresent([QueuedWorkbenchSend].self, forKey: .queuedSends) ?? []
        runProfiles = try c.decodeIfPresent([UUID: RunProfileStateSnapshot].self, forKey: .runProfiles) ?? [:]
        prCache = try c.decodeIfPresent([UUID: PRCacheStateSnapshot].self, forKey: .prCache) ?? [:]
        checkpoints = try c.decodeIfPresent([UUID: [CheckpointStateSnapshot]].self, forKey: .checkpoints) ?? [:]
        refresh = try c.decodeIfPresent(WorkbenchRefreshState.self, forKey: .refresh) ?? WorkbenchRefreshState()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

final class WorkbenchStateStore {
    private struct StoreFile: Codable {
        var schemaVersion: Int
        var snapshot: WorkbenchStateSnapshot
    }

    static let currentSchemaVersion = 1

    let storeURL: URL

    init(storeURL: URL = WorkbenchStateStore.defaultStoreURL()) {
        self.storeURL = storeURL
    }

    static func defaultStoreURL() -> URL {
        WorkspaceStore.defaultStoreURL()
            .deletingLastPathComponent()
            .appendingPathComponent("workbench-state.json")
    }

    func load() -> WorkbenchStateSnapshot {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return WorkbenchStateSnapshot()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: storeURL)
            if let file = try? decoder.decode(StoreFile.self, from: data) {
                return file.snapshot
            }
            return try decoder.decode(WorkbenchStateSnapshot.self, from: data)
        } catch {
            return WorkbenchStateSnapshot()
        }
    }

    func save(_ snapshot: WorkbenchStateSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = StoreFile(schemaVersion: Self.currentSchemaVersion, snapshot: snapshot)
        do {
            try FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(file)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            assertionFailure("Failed to save workbench-state.json: \(error)")
        }
    }
}

@MainActor
final class WorkbenchState: ObservableObject {
    @Published private(set) var snapshot: WorkbenchStateSnapshot

    private let store: WorkbenchStateStore
    private var lastPersistedWorkspaceWidth: Double

    init(store: WorkbenchStateStore = WorkbenchStateStore()) {
        self.store = store
        let loaded = store.load()
        self.snapshot = loaded
        self.lastPersistedWorkspaceWidth = loaded.workspaceWidth
    }

    var selectedSessionId: UUID? { snapshot.selectedSessionId }
    var selectedRightPane: WorkbenchPaneTab { snapshot.selectedRightPane }
    var showingReviewPane: Bool { snapshot.showingReviewPane }
    var density: TranscriptDensity { snapshot.density }
    var workspaceWidth: CGFloat { CGFloat(snapshot.workspaceWidth) }
    var queuedSends: [QueuedWorkbenchSend] { snapshot.queuedSends }

    func selectSession(_ id: UUID?) {
        update {
            $0.selectedSessionId = id
            if let id, let tab = $0.selectedRightPaneBySession[id] {
                $0.selectedRightPane = tab
            }
        }
    }

    func selectRightPane(_ tab: WorkbenchPaneTab) {
        update {
            $0.selectedRightPane = tab
            if let sessionId = $0.selectedSessionId {
                $0.selectedRightPaneBySession[sessionId] = tab
            }
        }
    }

    func setReviewPaneVisible(_ visible: Bool) {
        update { $0.showingReviewPane = visible }
    }

    func setDensity(_ density: TranscriptDensity) {
        update { $0.density = density }
    }

    func updateWorkspaceWidth(_ width: CGFloat) {
        let newWidth = Double(width)
        var copy = snapshot
        copy.workspaceWidth = newWidth
        copy.updatedAt = Date()
        snapshot = copy
        if abs(lastPersistedWorkspaceWidth - newWidth) >= 8 {
            lastPersistedWorkspaceWidth = newWidth
            store.save(copy)
        }
    }

    func markRefreshStarted() {
        update {
            $0.refresh.generation += 1
            $0.refresh.startedAt = Date()
        }
    }

    func markRefreshCompleted() {
        update {
            $0.refresh.completedAt = Date()
        }
    }

    func queueSend(_ draft: QueuedWorkbenchSend) {
        update { $0.queuedSends.append(draft) }
    }

    func queuedSends(for sessionId: UUID) -> [QueuedWorkbenchSend] {
        snapshot.queuedSends
            .filter { $0.sessionId == sessionId }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func queuedSendCount(for sessionId: UUID) -> Int {
        snapshot.queuedSends.filter { $0.sessionId == sessionId }.count
    }

    func nextQueuedSend(for sessionId: UUID) -> QueuedWorkbenchSend? {
        queuedSends(for: sessionId).first
    }

    func updateQueuedSend(id: UUID, text: String) {
        update { snapshot in
            guard let index = snapshot.queuedSends.firstIndex(where: { $0.id == id }) else { return }
            snapshot.queuedSends[index].text = text
        }
    }

    func removeQueuedSend(id: UUID) {
        update { $0.queuedSends.removeAll { $0.id == id } }
    }

    func clearQueuedSends(sessionId: UUID) {
        update { $0.queuedSends.removeAll { $0.sessionId == sessionId } }
    }

    func recordRunProfile(_ profile: RunProfileStateSnapshot) {
        guard let sessionId = profile.sessionId else { return }
        update { $0.runProfiles[sessionId] = profile }
    }

    func runProfile(for sessionId: UUID) -> RunProfileStateSnapshot? {
        snapshot.runProfiles[sessionId]
    }

    func recordPRCache(_ cache: PRCacheStateSnapshot) {
        update { $0.prCache[cache.sessionId] = cache }
    }

    func recordCheckpoint(_ checkpoint: CheckpointStateSnapshot) {
        update { $0.checkpoints[checkpoint.sessionId, default: []].append(checkpoint) }
        LifecycleWebSocketChannel.notifyCheckpointStateChanged(sessionId: checkpoint.sessionId)
    }

    func checkpoints(for sessionId: UUID) -> [CheckpointStateSnapshot] {
        (snapshot.checkpoints[sessionId] ?? [])
            .sorted { $0.createdAt > $1.createdAt }
    }

    func latestCheckpoint(for sessionId: UUID) -> CheckpointStateSnapshot? {
        checkpoints(for: sessionId).first
    }

    func clearSessionState(sessionId: UUID, preserveCheckpoints: Bool = true) {
        update {
            $0.queuedSends.removeAll { $0.sessionId == sessionId }
            $0.runProfiles.removeValue(forKey: sessionId)
            $0.prCache.removeValue(forKey: sessionId)
            $0.selectedRightPaneBySession.removeValue(forKey: sessionId)
            if !preserveCheckpoints {
                $0.checkpoints.removeValue(forKey: sessionId)
            }
        }
    }

    private func update(_ apply: (inout WorkbenchStateSnapshot) -> Void) {
        var copy = snapshot
        apply(&copy)
        copy.updatedAt = Date()
        snapshot = copy
        store.save(copy)
    }
}

struct CheckpointService {
    enum Error: LocalizedError, Equatable {
        case gitUnavailable
        case invalidRepository(String)
        case noHead
        case dirtyWorktree
        case restoreBlocked([String])
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .gitUnavailable:
                return "git is not available."
            case .invalidRepository(let cwd):
                return "Not a git workspace: \(cwd)"
            case .noHead:
                return "No HEAD commit to checkpoint."
            case .dirtyWorktree:
                return "Restore requires a clean working tree."
            case .restoreBlocked(let reasons):
                return reasons.joined(separator: "\n")
            case .commandFailed(let message):
                return message.isEmpty ? "Checkpoint command failed." : message
            }
        }
    }

    private let runner: ShellRunning
    private let gitLocator: @Sendable () -> String?
    private let now: @Sendable () -> Date

    init(
        runner: ShellRunning = ShellRunner.shared,
        gitLocator: @escaping @Sendable () -> String? = { ShellRunner.locateBinary("git") },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.gitLocator = gitLocator
        self.now = now
    }

    func createCheckpoint(
        session: AgentSession,
        turnId: String? = nil,
        summary: String? = nil
    ) async throws -> CheckpointStateSnapshot {
        guard let git = gitLocator() else { throw Error.gitUnavailable }
        let cwd = session.effectiveCwd
        try await assertGitRepository(git: git, cwd: cwd)
        let head = try await runner.run(
            executable: git,
            arguments: ["rev-parse", "--verify", "HEAD"],
            cwd: cwd,
            environment: nil,
            timeout: 10
        )
        guard head.exitStatus == 0 else { throw Error.noHead }

        let snapshotObject = try await checkpointObject(git: git, cwd: cwd)
        let createdAt = now()
        let refName = Self.refName(sessionId: session.id, createdAt: createdAt)
        let update = try await runner.run(
            executable: git,
            arguments: ["update-ref", refName, snapshotObject],
            cwd: cwd,
            environment: nil,
            timeout: 10
        )
        guard update.exitStatus == 0 else {
            throw Error.commandFailed(update.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let untrackedPaths = (try? await snapshotUntrackedFiles(
            git: git,
            cwd: cwd,
            sessionId: session.id,
            refName: refName
        )) ?? []

        return CheckpointStateSnapshot(
            sessionId: session.id,
            refName: refName,
            turnId: turnId,
            createdAt: createdAt,
            summary: summary ?? (untrackedPaths.isEmpty ? nil : "Includes \(untrackedPaths.count) untracked file\(untrackedPaths.count == 1 ? "" : "s")")
        )
    }

    func prepareRestore(
        _ checkpoint: CheckpointStateSnapshot,
        session: AgentSession
    ) async throws -> CheckpointRestorePlan {
        guard let git = gitLocator() else { throw Error.gitUnavailable }
        let cwd = session.effectiveCwd
        try await assertGitRepository(git: git, cwd: cwd)
        try await verifyRef(git: git, refName: checkpoint.refName, cwd: cwd)

        let safety = try await createSafetyCheckpoint(
            git: git,
            session: session,
            summary: "Safety before restoring \(checkpoint.refName)"
        )
        let statusLines = try await statusPorcelain(git: git, cwd: cwd)
        let dirtyTracked = statusLines.filter { !$0.hasPrefix("?? ") }
        let targetTracked = try await treePaths(git: git, refName: checkpoint.refName, cwd: cwd)
        let untracked = try await untrackedPaths(git: git, cwd: cwd)
        let untrackedOverwrite = untracked.filter { targetTracked.contains($0) }.sorted()
        let untrackedSnapshot = (try? await readUntrackedManifest(
            git: git,
            cwd: cwd,
            sessionId: checkpoint.sessionId,
            refName: checkpoint.refName
        )) ?? []

        let diffStat = try await diffOutput(
            git: git,
            arguments: ["diff", "--stat", "--find-renames", "HEAD", checkpoint.refName, "--", "."],
            cwd: cwd,
            timeout: 15
        )
        let rawPatch = try await diffOutput(
            git: git,
            arguments: ["diff", "--find-renames", "--unified=3", "HEAD", checkpoint.refName, "--", "."],
            cwd: cwd,
            timeout: 20
        )
        let maxPatchCharacters = 15_000
        let patchTruncated = rawPatch.count > maxPatchCharacters
        let diffPatch = patchTruncated ? String(rawPatch.prefix(maxPatchCharacters)) : rawPatch

        var blocking: [String] = []
        if !dirtyTracked.isEmpty {
            blocking.append("Working tree has uncommitted tracked or staged changes.")
        }
        if !untrackedOverwrite.isEmpty {
            blocking.append("Untracked files would be overwritten: \(untrackedOverwrite.prefix(5).joined(separator: ", "))")
        }

        return CheckpointRestorePlan(
            target: checkpoint,
            safety: safety,
            diffStat: diffStat,
            diffPatch: diffPatch,
            patchTruncated: patchTruncated,
            dirtyStatusLines: statusLines,
            untrackedOverwritePaths: untrackedOverwrite,
            untrackedSnapshotPaths: untrackedSnapshot,
            blockingReasons: blocking
        )
    }

    func restore(_ checkpoint: CheckpointStateSnapshot, in cwd: String) async throws {
        let session = AgentSession(
            id: checkpoint.sessionId,
            repoKey: cwd,
            repoDisplayName: URL(fileURLWithPath: cwd).lastPathComponent,
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .done,
            planText: nil,
            createdAt: checkpoint.createdAt,
            lastEventAt: checkpoint.createdAt,
            lastEventSeq: 0,
            runtimeCwd: cwd
        )
        let plan = try await prepareRestore(checkpoint, session: session)
        try await restore(plan, in: cwd)
    }

    func restore(_ plan: CheckpointRestorePlan, in cwd: String) async throws {
        guard !plan.isBlocked else { throw Error.restoreBlocked(plan.blockingReasons) }
        guard let git = gitLocator() else { throw Error.gitUnavailable }
        try await assertGitRepository(git: git, cwd: cwd)
        try await verifyRef(git: git, refName: plan.target.refName, cwd: cwd)
        let statusLines = try await statusPorcelain(git: git, cwd: cwd)
        let dirtyTracked = statusLines.filter { !$0.hasPrefix("?? ") }
        let targetTracked = try await treePaths(git: git, refName: plan.target.refName, cwd: cwd)
        let untrackedOverwrite = try await untrackedPaths(git: git, cwd: cwd)
            .filter { targetTracked.contains($0) }
            .sorted()
        var blocking: [String] = []
        if !dirtyTracked.isEmpty {
            blocking.append("Working tree has uncommitted tracked or staged changes.")
        }
        if !untrackedOverwrite.isEmpty {
            blocking.append("Untracked files would be overwritten: \(untrackedOverwrite.prefix(5).joined(separator: ", "))")
        }
        guard blocking.isEmpty else { throw Error.restoreBlocked(blocking) }
        try await performRestore(git: git, checkpoint: plan.target, cwd: cwd)
        try await restoreUntrackedSnapshot(git: git, checkpoint: plan.target, cwd: cwd)
    }

    static func refName(sessionId: UUID, createdAt: Date) -> String {
        let stamp = refStamp(createdAt)
        let unique = UUID().uuidString.prefix(8)
        return "refs/clawdmeter/checkpoints/\(sessionId.uuidString)/\(stamp)-\(unique)"
    }

    private static func refStamp(_ date: Date) -> String {
        let nanos = Int64((date.timeIntervalSince1970 * 1_000_000_000).rounded(.towardZero))
        return String(nanos)
    }

    private func assertGitRepository(git: String, cwd: String) async throws {
        let result = try await runner.run(
            executable: git,
            arguments: ["rev-parse", "--is-inside-work-tree"],
            cwd: cwd,
            environment: nil,
            timeout: 10
        )
        let ok = result.exitStatus == 0
            && result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        guard ok else { throw Error.invalidRepository(cwd) }
    }

    private func createSafetyCheckpoint(
        git: String,
        session: AgentSession,
        summary: String
    ) async throws -> CheckpointStateSnapshot {
        let cwd = session.effectiveCwd
        let head = try await runner.run(
            executable: git,
            arguments: ["rev-parse", "--verify", "HEAD"],
            cwd: cwd,
            environment: nil,
            timeout: 10
        )
        guard head.exitStatus == 0 else { throw Error.noHead }

        let snapshotObject = try await checkpointObject(git: git, cwd: cwd)
        let createdAt = now()
        let stamp = Self.refStamp(createdAt)
        let suffix = "safety-\(stamp)-\(UUID().uuidString.prefix(8))"
        let refName = "refs/clawdmeter/checkpoints/\(session.id.uuidString)/\(suffix)"
        let update = try await runner.run(
            executable: git,
            arguments: ["update-ref", refName, snapshotObject],
            cwd: cwd,
            environment: nil,
            timeout: 10
        )
        guard update.exitStatus == 0 else {
            throw Error.commandFailed(update.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        _ = try? await snapshotUntrackedFiles(git: git, cwd: cwd, sessionId: session.id, refName: refName)
        return CheckpointStateSnapshot(
            sessionId: session.id,
            refName: refName,
            turnId: suffix,
            createdAt: createdAt,
            summary: summary
        )
    }

    private func verifyRef(git: String, refName: String, cwd: String) async throws {
        let verify = try await runner.run(
            executable: git,
            arguments: ["rev-parse", "--verify", refName],
            cwd: cwd,
            environment: nil,
            timeout: 10
        )
        guard verify.exitStatus == 0 else {
            throw Error.commandFailed("Checkpoint ref no longer exists.")
        }
    }

    private func checkpointObject(git: String, cwd: String) async throws -> String {
        let stash = try await runner.run(
            executable: git,
            arguments: ["stash", "create", "clawdmeter checkpoint"],
            cwd: cwd,
            environment: nil,
            timeout: 20
        )
        guard stash.exitStatus == 0 else {
            throw Error.commandFailed(stash.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let object = stash.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return object.isEmpty ? "HEAD" : object
    }

    private func performRestore(git: String, checkpoint: CheckpointStateSnapshot, cwd: String) async throws {
        let restore = try await runner.run(
            executable: git,
            arguments: ["restore", "--source", checkpoint.refName, "--staged", "--worktree", "--", "."],
            cwd: cwd,
            environment: nil,
            timeout: 20
        )
        guard restore.exitStatus == 0 else {
            throw Error.commandFailed(restore.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func statusPorcelain(git: String, cwd: String) async throws -> [String] {
        let status = try await runner.run(
            executable: git,
            arguments: ["status", "--porcelain"],
            cwd: cwd,
            environment: nil,
            timeout: 10
        )
        guard status.exitStatus == 0 else {
            throw Error.commandFailed(status.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return status.stdoutString
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func diffOutput(git: String, arguments: [String], cwd: String, timeout: TimeInterval) async throws -> String {
        let result = try await runner.run(
            executable: git,
            arguments: arguments,
            cwd: cwd,
            environment: nil,
            timeout: timeout
        )
        guard result.exitStatus == 0 else {
            throw Error.commandFailed(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func treePaths(git: String, refName: String, cwd: String) async throws -> Set<String> {
        let result = try await runner.run(
            executable: git,
            arguments: ["ls-tree", "-r", "--name-only", refName],
            cwd: cwd,
            environment: nil,
            timeout: 10
        )
        guard result.exitStatus == 0 else {
            throw Error.commandFailed(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Set(result.stdoutString.split(whereSeparator: \.isNewline).map(String.init))
    }

    private func untrackedPaths(git: String, cwd: String) async throws -> [String] {
        let result = try await runner.run(
            executable: git,
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
            cwd: cwd,
            environment: nil,
            timeout: 10
        )
        guard result.exitStatus == 0 else {
            throw Error.commandFailed(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdoutString
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private struct UntrackedManifest: Codable {
        var paths: [String]
        var skipped: [String]
    }

    private func snapshotUntrackedFiles(
        git: String,
        cwd: String,
        sessionId: UUID,
        refName: String
    ) async throws -> [String] {
        let paths = try await untrackedPaths(git: git, cwd: cwd)
        guard !paths.isEmpty else { return [] }
        let root = try await sidecarDirectory(git: git, cwd: cwd, sessionId: sessionId, refName: refName)
        let untrackedRoot = root.appendingPathComponent("untracked", isDirectory: true)
        try FileManager.default.createDirectory(at: untrackedRoot, withIntermediateDirectories: true)

        var copied: [String] = []
        var skipped: [String] = []
        var totalBytes: UInt64 = 0
        let maxFiles = 100
        let maxFileBytes: UInt64 = 2 * 1024 * 1024
        let maxTotalBytes: UInt64 = 20 * 1024 * 1024
        for path in paths.prefix(maxFiles) {
            let source = URL(fileURLWithPath: cwd).appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                skipped.append(path)
                continue
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
            let size = attrs?[.size] as? UInt64 ?? 0
            guard size <= maxFileBytes, totalBytes + size <= maxTotalBytes else {
                skipped.append(path)
                continue
            }
            let destination = untrackedRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            copied.append(path)
            totalBytes += size
        }
        if paths.count > maxFiles {
            skipped.append(contentsOf: paths.dropFirst(maxFiles))
        }
        let manifest = UntrackedManifest(paths: copied, skipped: skipped)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent("untracked-manifest.json"), options: [.atomic])
        return copied
    }

    private func readUntrackedManifest(
        git: String,
        cwd: String,
        sessionId: UUID,
        refName: String
    ) async throws -> [String] {
        let root = try await sidecarDirectory(git: git, cwd: cwd, sessionId: sessionId, refName: refName)
        let manifestURL = root.appendingPathComponent("untracked-manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let manifest = try JSONDecoder().decode(UntrackedManifest.self, from: Data(contentsOf: manifestURL))
        return manifest.paths
    }

    private func restoreUntrackedSnapshot(
        git: String,
        checkpoint: CheckpointStateSnapshot,
        cwd: String
    ) async throws {
        let root = try await sidecarDirectory(
            git: git,
            cwd: cwd,
            sessionId: checkpoint.sessionId,
            refName: checkpoint.refName
        )
        let untrackedRoot = root.appendingPathComponent("untracked", isDirectory: true)
        guard FileManager.default.fileExists(atPath: untrackedRoot.path) else { return }
        let paths = try await readUntrackedManifest(
            git: git,
            cwd: cwd,
            sessionId: checkpoint.sessionId,
            refName: checkpoint.refName
        )
        for path in paths {
            let source = untrackedRoot.appendingPathComponent(path)
            let destination = URL(fileURLWithPath: cwd).appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: source.path),
                  !FileManager.default.fileExists(atPath: destination.path)
            else { continue }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func sidecarDirectory(git: String, cwd: String, sessionId: UUID, refName: String) async throws -> URL {
        let suffix = refName
            .replacingOccurrences(of: "refs/clawdmeter/checkpoints/\(sessionId.uuidString)/", with: "")
            .replacingOccurrences(of: "/", with: "_")
        let rel = "clawdmeter/checkpoints/\(sessionId.uuidString)/\(suffix)"
        let result = try await runner.run(
            executable: git,
            arguments: ["rev-parse", "--git-path", rel],
            cwd: cwd,
            environment: nil,
            timeout: 10
        )
        guard result.exitStatus == 0 else {
            throw Error.commandFailed(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let raw = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(raw, isDirectory: true)
    }
}
