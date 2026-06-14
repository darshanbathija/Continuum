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
/// Persists `sessions.json` schema v3 to `~/Library/Application Support/
/// Clawdmeter/sessions.json` for restart resilience.
///
/// Sessions v2 (T41 audit): every mutation goes through the single `with()`
/// helper so new fields (`effort`, `abPairSessionId`, `abPairDecidedAt`,
/// `abPairWinnerSessionId`)
/// propagate automatically. Adding a new field is a one-line change here
/// instead of N parallel constructor calls.
@MainActor
public final class AgentSessionRegistry: ObservableObject {

    @Published public private(set) var sessions: [AgentSession] = []

    /// Monotonic per-session event sequence. Backs E8 cursor contract.
    private var nextEventSeqBySession: [UUID: UInt64] = [:]

    /// In-memory record of when each session was last `markPlanApproved`'d.
    /// Drives the `PlanProgressComputer`'s post-approval timestamp filter
    /// (the filter is what prevents the plan-emission assistant message
    /// from self-completing every step). Not persisted: on daemon restart
    /// we lose the exact wall-clock and the first recompute treats every
    /// retained message as post-approval — a forgivable degradation.
    private var approvedAtBySession: [UUID: Date] = [:]

    /// Path to the sessions.json on-disk snapshot.
    private let storeURL: URL

    /// F2 — orchestration event store. Gated by
    /// `FeatureFlags.orchestrationEventStore` (default `true` since
    /// F2-wire). When set, the registry (a) seeds itself from event
    /// replay on init and (b) writes a receipt to the SQLite log
    /// BEFORE every in-memory mutation. The receipt write is awaited;
    /// if it throws, the mutation does NOT proceed and the error
    /// bubbles to the caller (so the daemon can decide: retry, surface
    /// to the user, fail loud).
    ///
    /// `nil` when the flag is off — legacy `sessions.json` snapshot
    /// path stays unchanged, mutation methods become "save the JSON
    /// snapshot only, no receipt." The flag stays in place so a
    /// rollback PR can flip it back to `false` if the wired path
    /// regresses in production.
    private let eventStore: OrchestrationEventStore?
    private var eventReplaySeedTask: Task<Void, Never>?

    public init(
        storeURL: URL = AgentSessionRegistry.defaultStoreURL(),
        eventStore: OrchestrationEventStore? = nil
    ) {
        self.storeURL = storeURL
        // Respect injected store (tests), else honor the feature flag.
        // Wrapping in `try?` so a corrupt-recovery on init never crashes
        // the daemon: store falls back to nil → legacy path.
        //
        // F2-wire: when the caller passed a custom `storeURL` (the test
        // pattern is `AgentSessionRegistry(storeURL: tempDir/sessions.json)`),
        // co-locate the orchestration event store in the same directory
        // so per-test isolation extends to the SQLite log. Without this,
        // every test that didn't explicitly inject `eventStore` would
        // share the user's real `~/Library/.../orchestration-events.sqlite`
        // and leak state across runs.
        if let injected = eventStore {
            self.eventStore = injected
        } else if FeatureFlags.orchestrationEventStore {
            let eventStoreURL: URL = {
                if storeURL == AgentSessionRegistry.defaultStoreURL() {
                    return OrchestrationEventStore.defaultStoreURL()
                }
                return storeURL.deletingLastPathComponent()
                    .appendingPathComponent("orchestration-events.sqlite")
            }()
            self.eventStore = try? OrchestrationEventStore(storeURL: eventStoreURL)
        } else {
            self.eventStore = nil
        }
        load()
        // F2 replay-on-init: if we opened an event store AND the JSON
        // snapshot was empty (cold start on a fresh install where the
        // flag is on) AND the event log has anything, seed state from
        // replay. Replay is scheduled asynchronously so constructing
        // the registry never parks the MainActor during Code-tab startup.
        if let store = self.eventStore, sessions.isEmpty {
            seedFromEventReplayIfPossible(store: store)
        }
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

    // MARK: - F2-wire event store hooks (write-ahead-receipt invariant)

    /// Public write-ahead API. Writes `command` to the SQLite event log
    /// and surfaces failure to the caller — the contract is "the receipt
    /// has been durably appended when this method returns; if it throws,
    /// it has NOT been written and the caller MUST NOT mutate in-memory
    /// state on the assumption that it has."
    ///
    /// F2-wire changed this from the F2-foundation fire-and-forget shape
    /// (`Task { try? await store.append(...) }`) which violated the
    /// documented write-ahead invariant: discarding the error meant a
    /// SQLite failure left the in-memory state ahead of the log, and
    /// replay on restart would silently lose mutations.
    ///
    /// No-op (returns immediately) when the feature flag is off — the
    /// flag's `false` rollback path takes over and the registry runs in
    /// legacy `sessions.json`-snapshot mode unchanged.
    public func recordCommand(_ command: OrchestrationCommand) async throws {
        guard let store = eventStore else { return }
        _ = try await store.append(command)
    }

    /// Internal write-ahead helper. Encodes the session as the receipt
    /// payload and appends via `recordCommand`. The kind discriminator
    /// drives replay branching (created / deleted / approved / completed
    /// / failed / interrupted / metadataUpdated). When `eventStore` is
    /// nil (flag off) this is a cheap no-op.
    private func writeReceipt(
        kind: OrchestrationCommand.Kind,
        sessionId: UUID,
        session: AgentSession?,
        source: String = "registry"
    ) async throws {
        guard eventStore != nil else { return }
        let payload: Data
        if let session {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            payload = (try? encoder.encode(session)) ?? Data()
        } else {
            payload = Data()
        }
        let command = OrchestrationCommand(
            source: source,
            kind: kind,
            sessionId: sessionId.uuidString,
            timestamp: Date(),
            runtimeEvent: nil,
            payload: payload
        )
        try await recordCommand(command)
    }

    /// Public hook for opportunistic WAL checkpointing. The daemon calls
    /// this on application termination + at sensible idle intervals so
    /// the WAL sidecar stays bounded (a privacy-relevant guarantee — see
    /// `OrchestrationEventStore.deleteSession(_:)` for the deeper note).
    /// No-op when the flag is off.
    public func checkpointEventStore() async {
        guard let store = eventStore else { return }
        do {
            try await store.checkpoint()
        } catch {
            registryLogger.error("OrchestrationEventStore.checkpoint failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Replays the event log and rebuilds the `sessions` projection.
    /// Called from init when the JSON snapshot is empty + the event store
    /// has events (the cold-start-after-restart case during rollout).
    ///
    /// Replay rule (foundation PR): build a per-session projection by
    /// applying each event's payload, last-write-wins per session id. The
    /// payload SHOULD be a JSON-encoded `AgentSession` for create / update
    /// commands; commands without payload are skipped on the projection
    /// side (delete commands are still applied — they remove the session).
    ///
    /// The F2-wire PR will tighten this — once every mutation writes a
    /// receipt, the JSON snapshot becomes derivable and the replay handler
    /// becomes the authoritative loader.
    private func seedFromEventReplayIfPossible(store: OrchestrationEventStore) {
        eventReplaySeedTask?.cancel()
        eventReplaySeedTask = Task { [store] in
            guard
                let replayed = await Self.replaySessions(store: store),
                !replayed.isEmpty,
                !Task.isCancelled
            else { return }

            var currentById = Dictionary(uniqueKeysWithValues: self.sessions.map { ($0.id, $0) })
            var seen = Set<UUID>()
            var merged: [AgentSession] = []
            merged.reserveCapacity(replayed.count + self.sessions.count)
            for replaySession in replayed {
                merged.append(currentById.removeValue(forKey: replaySession.id) ?? replaySession)
                seen.insert(replaySession.id)
            }
            for liveSession in self.sessions where seen.insert(liveSession.id).inserted {
                merged.append(liveSession)
            }

            // Same retired-tmux revival the JSON loader applies — a legacy Claude
            // session reconstructed only from the event log must also shed its
            // dead pane metadata so it routes to `.claudePty`.
            let retiredClaudePaneCount = merged.filter {
                $0.agent == .claude && ($0.tmuxPaneId != nil || $0.tmuxWindowId != nil)
            }.count
            self.sessions = migratingRetiredClaudePanes(merged)
            self.nextEventSeqBySession.removeAll(keepingCapacity: true)
            for session in merged {
                self.nextEventSeqBySession[session.id] = session.lastEventSeq + 1
            }
            // Persist the one-time strip (parity with load()) so an event-log-only
            // revived session isn't re-stripped + re-stamped (lastEventAt) every
            // launch, which would re-float it to the top of the activity sort.
            if retiredClaudePaneCount > 0 { save() }
            registryLogger.info("Seeded \(replayed.count) replayed sessions into \(merged.count) live sessions")
        }
    }

    @discardableResult
    func waitForEventReplaySeedForTesting() async -> Bool {
        guard let task = eventReplaySeedTask else { return true }
        await task.value
        return true
    }

    func closeEventStoreForTesting() async {
        eventReplaySeedTask?.cancel()
        if let task = eventReplaySeedTask {
            await task.value
            eventReplaySeedTask = nil
        }
        guard let eventStore else { return }
        do {
            try await eventStore.close()
        } catch {
            registryLogger.error("OrchestrationEventStore close failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func replaySessions(store: OrchestrationEventStore) async -> [AgentSession]? {
        await Task.detached(priority: .utility) {
            do {
                let rows = try await store.loadAll(includeSnapshots: true)
                guard !rows.isEmpty else { return nil }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                var projection: [UUID: AgentSession] = [:]
                for row in rows {
                    switch row.command.kind {
                    case .sessionDeleted:
                        if let uuid = UUID(uuidString: row.command.sessionId) {
                            projection.removeValue(forKey: uuid)
                        }
                    case .sessionCreated, .sessionMetadataUpdated,
                         .sessionApproved, .sessionInterrupted,
                         .sessionCompleted, .sessionFailed:
                        guard !row.command.payload.isEmpty else { continue }
                        if let session = try? decoder.decode(AgentSession.self, from: row.command.payload) {
                            projection[session.id] = session
                        }
                    }
                }
                return Array(projection.values)
            } catch {
                registryLogger.error("OrchestrationEventStore replay failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
    }

    // MARK: - Mutations

    /// Create a new session record. Caller (handle POST /sessions) has already
    /// prepared the runtime; we record the metadata.
    ///
    /// F2-wire: `async throws` so the `sessionCreated` receipt lands in
    /// the SQLite log BEFORE the in-memory mutation. If the receipt
    /// write fails, this throws and the session does NOT enter the
    /// projection — caller decides whether to retry, skip the spawn, or
    /// fail the HTTP request.
    @discardableResult
    public func create(
        repoKey: String,
        repoDisplayName: String,
        agent: AgentKind,
        model: String?,
        goal: String?,
        worktreePath: String?,
        provisioning: WorktreeProvisioningMetadata? = nil,
        tmuxWindowId: String?,
        tmuxPaneId: String?,
        planMode: Bool,
        mode: SessionMode = .local,
        parentSessionId: UUID? = nil,
        effort: ReasoningEffort? = nil,
        abPairSessionId: UUID? = nil,
        // v0.8.0 agy-migration — Gemini sessions spawned through
        inheritedContextSourceIds: [UUID]? = nil,
        ownsWorktree: Bool = false,
        envSetId: UUID? = nil,
        envSetName: String? = nil,
        providerInstanceId: String? = nil,
        customProviderId: String? = nil,
        executionHostId: UUID? = nil,
        executionHostLabel: String? = nil,
        id: UUID = UUID()
    ) async throws -> AgentSession {
        let now = Date()
        let hostMeta = Self.executionHostMetadata(
            executionHostId: executionHostId,
            executionHostLabel: executionHostLabel
        )
        let session = AgentSession(
            id: id,
            repoKey: repoKey,
            repoDisplayName: repoDisplayName,
            agent: agent,
            model: model,
            goal: goal,
            worktreePath: worktreePath,
            provisioning: provisioning,
            tmuxWindowId: tmuxWindowId,
            tmuxPaneId: tmuxPaneId,
            status: planMode ? .planning : .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 1,
            mode: mode,
            parentSessionId: parentSessionId,
            runtimeCwd: worktreePath ?? repoKey,
            runtimeBinding: Self.makeRuntimeBinding(
                agent: agent,
                model: model,
                codexBackend: nil,
                billingProvider: customProviderId
            ),
            effort: effort,
            abPairSessionId: abPairSessionId,
            providerInstanceId: providerInstanceId,
            inheritedContextSourceIds: inheritedContextSourceIds,
            ownsWorktree: ownsWorktree,
            envSetId: envSetId,
            envSetName: envSetName,
            customProviderId: customProviderId,
            executionHostId: hostMeta.id,
            executionHostLabel: hostMeta.label
        )
        // Write-ahead: receipt lands BEFORE in-memory mutation. If the
        // event store rejects the write, we propagate and the caller
        // (HTTP handler) returns 503 / 500 to the client without ever
        // exposing the half-created session.
        try await writeReceipt(kind: .sessionCreated, sessionId: id, session: session)
        nextEventSeqBySession[id] = 1
        sessions.append(session)
        HostRunMinuteStore.shared.sessionStarted(session)
        save()
        return session
    }

    /// v0.8 Chat tab: create a chat-kind session. Stores the chat-cwd in
    /// `worktreePath` (so the existing `effectiveCwd` dispatch resolves to
    /// it) and leaves `repoKey` nil (chat sessions have no repo). v0.9
    /// adds the agentapi binding fields so Gemini chat sessions can
    /// persist their conversation/project ids at create time without a
    /// separate update pass.
    public func createChat(
        provider: AgentKind,
        model: String?,
        chatCwd: String,
        codexChatBackend: CodexChatBackend? = nil,
        effort: ReasoningEffort? = nil,
        frontierGroupId: UUID? = nil,
        frontierChildIndex: Int? = nil,
        deepResearch: Bool = false,
        chatVendor: ChatVendor? = nil,
        billingProvider: String? = nil,
        providerInstanceId: String? = nil,
        customProviderId: String? = nil,
        executionHostId: UUID? = nil,
        executionHostLabel: String? = nil
    ) async throws -> AgentSession {
        let id = UUID()
        let now = Date()
        let hostMeta = Self.executionHostMetadata(
            executionHostId: executionHostId,
            executionHostLabel: executionHostLabel
        )
        // v0.9: chat-mode Frontier children carry a slightly different
        // display label so the sidebar can group them visually under the
        // group's row. Defaults to the v0.8 "Chat — {Provider}" string.
        let displayName: String = {
            if let idx = frontierChildIndex {
                return "Frontier #\(idx + 1) — \(AgentKindUI.displayName(for: provider))"
            }
            return "Chat — \(AgentKindUI.displayName(for: provider))"
        }()
        let session = AgentSession(
            id: id,
            repoKey: nil,
            repoDisplayName: displayName,
            agent: provider,
            model: model,
            goal: nil,
            worktreePath: chatCwd,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: now,
            lastEventAt: now,
            lastEventSeq: 1,
            mode: .local,
            runtimeCwd: chatCwd,
            chatCwd: chatCwd,
            runtimeBinding: Self.makeRuntimeBinding(
                agent: provider,
                model: model,
                codexBackend: codexChatBackend,
                chatVendor: chatVendor,
                billingProvider: customProviderId ?? billingProvider
            ),
            effort: effort,
            kind: .chat,
            frontierGroupId: frontierGroupId,
            frontierChildIndex: frontierChildIndex,
            codexChatBackend: codexChatBackend,
            deepResearch: deepResearch,
            providerInstanceId: providerInstanceId,
            customProviderId: customProviderId,
            executionHostId: hostMeta.id,
            executionHostLabel: hostMeta.label
        )
        // Write-ahead: see comment on `create(...)`. Chat sessions take
        // the same receipt path so replay reconstructs both `code` and
        // `chat` projections on cold start.
        try await writeReceipt(kind: .sessionCreated, sessionId: id, session: session)
        nextEventSeqBySession[id] = 1
        sessions.append(session)
        HostRunMinuteStore.shared.sessionStarted(session)
        save()
        return session
    }

    /// v0.9 — read all sessions in a Frontier group, sorted by
    /// `frontierChildIndex`. Used by the Frontier WS snapshotter +
    /// HTTP handlers (send fan-out, retry-slot, pick-winner).
    ///
    /// Defaults to excluding archived children so Frontier send fan-out
    /// and snapshot subscribers see only live panes. Callers that need
    /// the full set (e.g. pick-winner enumerating losers to archive)
    /// pass `includeArchived: true`.
    public func frontierGroupChildren(groupId: UUID, includeArchived: Bool = false) -> [AgentSession] {
        sessions
            .filter { $0.frontierGroupId == groupId && (includeArchived || $0.archivedAt == nil) }
            .sorted { ($0.frontierChildIndex ?? Int.max) < ($1.frontierChildIndex ?? Int.max) }
    }

    /// v0.23.9 — clear the Frontier group binding on the winning child
    /// so continue-from-winner converts it into a regular Solo chat in
    /// the sidebar + history. The winner's JSONL transcript is
    /// preserved; only the `frontierGroupId` / `frontierChildIndex`
    /// fields are dropped.
    public func clearFrontierGroupBinding(id: UUID) async throws {
        guard let s = session(id: id) else { return }
        let projected = with(
            s,
            frontierGroupId: .some(nil),
            frontierChildIndex: .some(nil)
        )
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
    }


    /// Update the persisted codex thread id for an SDK chat session after
    /// the first turn returns its `thread.started` event. Lets resume-
    /// after-evict in Phase 4.5 find the same server-side thread.
    public func setCodexChatThreadId(id: UUID, threadId: String) async throws {
        guard let s = session(id: id) else { return }
        let binding = (s.runtimeBinding ?? Self.makeRuntimeBinding(
            agent: s.agent,
            model: s.model,
            codexBackend: s.codexChatBackend
        )).updating(externalThreadId: .some(threadId))
        let projected = with(s, codexChatThreadId: threadId, runtimeBinding: binding)
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
    }

    /// Clear the persisted Codex thread id (and the binding's external thread).
    /// A cross-vendor switch makes the old Codex server-side thread irrelevant;
    /// without this, a later Claude→Codex→same-vendor switch could try to resume
    /// a dead thread.
    public func clearCodexChatThreadId(id: UUID) async throws {
        guard let s = session(id: id), s.codexChatThreadId != nil else { return }
        let projected: AgentSession
        if let binding = s.runtimeBinding?.updating(externalThreadId: .some(nil)) {
            projected = with(s, codexChatThreadId: .some(nil), runtimeBinding: .some(binding))
        } else {
            projected = with(s, codexChatThreadId: .some(nil))
        }
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
    }

    public func session(id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    public func sessions(customProviderId: String) -> [AgentSession] {
        sessions.filter { $0.customProviderId == customProviderId }
    }

    /// Per-session monotonic event seq counter. Used by AgentEventStream.
    public func nextEventSeq(for sessionId: UUID) -> UInt64 {
        let next = (nextEventSeqBySession[sessionId] ?? 0) + 1
        nextEventSeqBySession[sessionId] = next
        return next
    }

    /// Status transition — the headline lifecycle event. Maps each
    /// status to a typed `OrchestrationCommand.Kind` so replay branches
    /// on intent (completed vs interrupted vs degraded), not just a
    /// generic "metadata updated" stream.
    public func updateStatus(id: UUID, status: AgentSessionStatus) async throws {
        guard let current = session(id: id) else { return }
        let projected = with(current, status: status, lastEventSeq: current.lastEventSeq + 1)
        let kind: OrchestrationCommand.Kind
        switch status {
        case .done:      kind = .sessionCompleted
        case .degraded:  kind = .sessionFailed
        case .paused:    kind = .sessionInterrupted
        case .planning, .running: kind = .sessionMetadataUpdated
        }
        try await writeReceipt(kind: kind, sessionId: id, session: projected)
        bumpEventSeq(id: id)
        update(id: id) { _ in projected }
    }

    public func setPlanText(id: UUID, planText: String) async throws {
        guard let current = session(id: id), current.planText != planText else { return }
        let projected = with(current, planText: planText, lastEventSeq: current.lastEventSeq + 1)
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        bumpEventSeq(id: id)
        update(id: id) { _ in projected }
    }

    public func markPlanApproved(id: UUID) async throws {
        guard let current = session(id: id) else { return }
        let approved = Self.reviewableApprovedPlanText(from: current)
        guard current.planText != nil || current.approvedPlanText != approved else { return }
        // Stamp approvedAt so subsequent `PlanProgressTracker` recomputes
        // can filter out the plan-emission assistant message — the message
        // whose `at` is at-or-before this stamp is the one that contains
        // the entire plan verbatim, and matching against it would
        // self-complete every step.
        let approvedAt = Date()
        // Compute the initial 0/N snapshot so the sidebar bar appears
        // immediately on approval instead of waiting for the first
        // post-approval JSONL event. Tracker fills in real completion
        // values as the agent works.
        let initialProgress: PlanProgress? = approved.flatMap { text in
            PlanProgressComputer.compute(
                approvedPlanText: text,
                messagesSinceApproval: [],
                approvedAt: approvedAt
            )
        }
        let projected = with(
            current,
            planText: .some(nil),
            approvedPlanText: approved,
            lastEventSeq: current.lastEventSeq + 1,
            planProgress: .some(initialProgress)
        )
        // Receipt kind is `.sessionApproved` so replay can distinguish
        // approval from generic metadata updates (the F2 plan calls out
        // "plan-approve" as one of the 7 first-class command kinds).
        try await writeReceipt(kind: .sessionApproved, sessionId: id, session: projected)
        bumpEventSeq(id: id)
        approvedAtBySession[id] = approvedAt
        update(id: id) { _ in projected }
    }

    /// Wall-clock of the most recent `markPlanApproved(id:)` for this
    /// session. `nil` after daemon restart (in-memory only). Callers
    /// (the `PlanProgressTracker`) fall back to `session.lastEventAt`
    /// when this returns nil — older retained messages still get the
    /// post-approval treatment, which is fine for the bar's purpose.
    public func approvedAt(for id: UUID) -> Date? {
        approvedAtBySession[id]
    }

    /// Daemon-driven setter for `AgentSession.planProgress`. Idempotent
    /// when the new value equals the existing one — matches the shape
    /// of `setPlanText` so callers can fire freely without thrashing
    /// `lastEventSeq`.
    public func setPlanProgress(id: UUID, progress: PlanProgress?) async throws {
        guard let current = session(id: id) else { return }
        guard current.planProgress != progress else { return }
        let projected = with(current, lastEventSeq: current.lastEventSeq + 1, planProgress: .some(progress))
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        bumpEventSeq(id: id)
        update(id: id) { _ in projected }
    }

    /// Update the in-place cwd/worktree metadata (used when the user switches
    /// the mode picker on a live session and we re-spawn the agent in a new
    /// directory).
    public func updateRuntime(
        id: UUID,
        worktreePath: String?,
        provisioning: WorktreeProvisioningMetadata?? = nil,
        runtimeCwd: String?? = nil,
        tmuxWindowId: String?,
        tmuxPaneId: String?,
        mode: SessionMode,
        ownsWorktree: Bool? = nil
    ) async throws {
        guard let s = session(id: id) else { return }
        let projected = with(
            s,
            worktreePath: worktreePath,
            provisioning: provisioning,
            tmuxWindowId: tmuxWindowId,
            tmuxPaneId: tmuxPaneId,
            mode: mode,
            runtimeCwd: runtimeCwd,
            ownsWorktree: ownsWorktree
        )
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
    }

    /// Hand worktree ownership to another session. Used when the session that
    /// provisioned a shared worktree is closed while siblings still live in it:
    /// ownership moves to a survivor so whichever tab closes LAST still cleans
    /// up the worktree (otherwise the orphaned worktree would never be deleted).
    public func transferWorktreeOwnership(to id: UUID) {
        update(id: id) { with($0, ownsWorktree: true) }
    }

    /// Sessions v2: swap model on a live session (Phase 0). `effort: nil`
    /// means "leave effort unchanged" — pass the existing value through so
    /// `with()`'s double-optional override semantics don't null it out.
    public func setModel(id: UUID, model: String, effort: ReasoningEffort?) async throws {
        guard let s = session(id: id) else { return }
        let binding = (s.runtimeBinding ?? Self.makeRuntimeBinding(
            agent: s.agent,
            model: model,
            codexBackend: s.codexChatBackend
        )).updating(providerModelId: .some(model))
        let projected = with(
            s,
            model: model,
            effort: .some(effort ?? s.effort),
            runtimeBinding: binding
        )
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
    }

    /// Update launch-time provider configuration for an optimistic session that
    /// has not attached its runtime yet. This is intentionally separate from the
    /// live SessionConfigChanger path: picker edits made while "+" provisioning
    /// is still running should alter the pending spawn request, not attempt a
    /// mid-session swap against an agent that does not exist yet.
    /// `customProviderId` is double-optional: outer nil = keep current; inner nil
    /// = explicitly clear (a cross-vendor switch off a custom provider). A live
    /// cross-vendor switch reuses this to repoint agent+model+effort+provider in
    /// one write, which also rebuilds `runtimeBinding` so the billing stack flips.
    public func setLaunchConfiguration(
        id: UUID,
        agent: AgentKind,
        model: String?,
        effort: ReasoningEffort?,
        customProviderId: String?? = nil
    ) async throws {
        guard let s = session(id: id) else { return }
        let resolvedCustom = Self.resolve(customProviderId, fallback: s.customProviderId)
        guard s.agent != agent || s.model != model || s.effort != effort || resolvedCustom != s.customProviderId else { return }
        let binding = Self.makeRuntimeBinding(
            agent: agent,
            model: model,
            codexBackend: s.codexChatBackend
        )
        let projected = with(
            s,
            agent: agent,
            model: .some(model),
            effort: .some(effort),
            runtimeBinding: binding,
            customProviderId: customProviderId
        )
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
    }

    /// Fast UI-only projection for optimistic "+" sessions. Picker changes can
    /// happen several times in a second, so they must not write SQLite receipts
    /// or rewrite sessions.json on every hover/click. The daemon adopt path calls
    /// `setLaunchConfiguration` once with the final choice.
    public func previewLaunchConfiguration(
        id: UUID,
        agent: AgentKind,
        model: String?,
        effort: ReasoningEffort?
    ) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions[idx]
        guard s.agent != agent || s.model != model || s.effort != effort else { return }
        let binding = Self.makeRuntimeBinding(
            agent: agent,
            model: model,
            codexBackend: s.codexChatBackend
        )
        var next = sessions
        next[idx] = with(
            s,
            agent: agent,
            model: .some(model),
            effort: .some(effort),
            runtimeBinding: binding
        )
        sessions = next
    }

    /// Sessions v2: swap effort on a live session (Phase 0).
    public func setEffort(id: UUID, effort: ReasoningEffort) async throws {
        guard let s = session(id: id) else { return }
        let projected = with(s, effort: effort)
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
    }

    /// Sessions v2: change plan mode mid-session (status flips to planning).
    public func setPlanMode(id: UUID, planMode: Bool) async throws {
        guard let s = session(id: id) else { return }
        let projected = with(s, status: planMode ? .planning : .running)
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
    }

    /// Archive (hide from default sidebar). Reversible via `unarchive(id:)`.
    /// If the session is one half of an A/B pair, the sibling's
    /// `abPairSessionId` is cleared automatically per D16.
    public func archive(id: UUID, at date: Date = Date()) async throws {
        try await archive(ids: [id], at: date)
    }

    /// Bulk archive used by Code sidebar "Archive all" paths. This keeps the
    /// write-ahead receipt contract, but avoids N full `sessions.json` saves and
    /// schedules worktree reclamation after the rows have disappeared.
    public func archive(ids rawIds: [UUID], at date: Date = Date()) async throws {
        var seen: Set<UUID> = []
        let ids = rawIds.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }

        var next = sessions
        var didMutate = false
        var toReclaim: [AgentSession] = []
        var receipts: [(UUID, AgentSession)] = []

        for id in ids {
            guard let idx = next.firstIndex(where: { $0.id == id }) else { continue }
            let s = next[idx]
            let projected = with(s, archivedAt: date)
            next[idx] = projected
            didMutate = true
            toReclaim.append(s)
            receipts.append((id, projected))

            // D16: promote sibling to standalone with banner. If the sibling is
            // also in the bulk archive set, its own projected archive will land
            // when that id is processed.
            if let siblingId = s.abPairSessionId,
               !seen.contains(siblingId),
               let siblingIdx = next.firstIndex(where: { $0.id == siblingId }) {
                let sibling = next[siblingIdx]
                let siblingProjected = with(sibling, abPairSessionId: .some(nil))
                next[siblingIdx] = siblingProjected
                receipts.append((siblingId, siblingProjected))
            }
        }

        // Publish the archived rows before WAL receipts so sidebar rows
        // disappear within the click budget even when the event store is on.
        if didMutate {
            sessions = next
            for id in ids {
                HostRunMinuteStore.shared.sessionStopped(id)
            }
            save()
            scheduleWorktreeReclaims(toReclaim)
        }

        for (sessionId, projected) in receipts {
            try await writeReceipt(
                kind: .sessionMetadataUpdated,
                sessionId: sessionId,
                session: projected
            )
        }
    }

    private func scheduleWorktreeReclaims(_ sessions: [AgentSession]) {
        guard !sessions.isEmpty else { return }
        Task { @MainActor in
            for session in sessions {
                await self.reclaimWorktreeOnArchive(session)
            }
        }
    }

    static func canReclaimWorktreeOnArchive(_ session: AgentSession) -> Bool {
        guard session.kind == .code,
              session.ownsWorktree,
              let worktreePath = session.worktreePath,
              let repoRoot = session.repoKey,
              worktreePath != repoRoot,
              worktreePath.contains("/Clawdmeter/workspaces/"),
              let provisioning = session.provisioning,
              !provisioning.ownershipMarkerId.isEmpty,
              provisioning.worktreePath == worktreePath
        else { return false }
        return true
    }

    /// Stop the runtime + move the session's worktree to the macOS Trash.
    /// No-op unless the session carries explicit Continuum-owned worktree
    /// metadata; a managed-looking path alone is not enough to touch user data.
    private func reclaimWorktreeOnArchive(_ s: AgentSession) async {
        guard Self.canReclaimWorktreeOnArchive(s),
              let wt = s.worktreePath,
              let repoRoot = s.repoKey else { return }
        await AppDelegate.runtime?.agentControlServer.teardownRuntimeForReclaim(id: s.id)
        await WorktreeManager.shared.trashWorktree(repoRoot: repoRoot, worktreePath: wt)
    }

    public func unarchive(id: UUID) async throws {
        guard let s = session(id: id) else { return }
        let projected = with(s, archivedAt: .some(nil))
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
        // Re-check-out the worktree archive moved to Trash, from its branch.
        if Self.canReclaimWorktreeOnArchive(s),
           let wt = s.worktreePath,
           let repoRoot = s.repoKey,
           let branch = s.provisioning?.branchName,
           !FileManager.default.fileExists(atPath: wt) {
            _ = await WorktreeManager.shared.reprovision(
                repoRoot: repoRoot, worktreePath: wt, branchName: branch
            )
        }
    }

    // MARK: - A/B pair operations (Phase 7 + E3 atomic CAS)

    /// Link two existing sessions as an A/B pair. Idempotent: re-linking
    /// the same pair is a no-op.
    public func linkABPair(_ a: UUID, _ b: UUID) async throws {
        if let sa = session(id: a) {
            let pa = with(sa, abPairSessionId: .some(b))
            try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: a, session: pa)
            update(id: a) { _ in pa }
        }
        if let sb = session(id: b) {
            let pb = with(sb, abPairSessionId: .some(a))
            try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: b, session: pb)
            update(id: b) { _ in pb }
        }
    }

    /// Atomic compare-and-set on A/B pair winner-pick. Returns the resolved
    /// decision (existing if already decided, new otherwise) or nil if the
    /// session id is unknown.
    ///
    /// E3: first request locks `abPairDecidedAt`; subsequent requests see
    /// the existing decision and the caller responds 409.
    public func pickPairWinner(sessionId: UUID, winner: UUID, at when: Date = Date()) async throws -> PickPairResult? {
        guard let s = session(id: sessionId) else { return nil }
        guard let siblingId = s.abPairSessionId else {
            return .notPaired
        }
        // Validate that the winner is one of the pair members.
        guard winner == sessionId || winner == siblingId else {
            return .invalidWinner
        }
        let sibling = session(id: siblingId)
        // Check both members for an existing decision (whichever was hit first).
        if let decidedAt = s.abPairDecidedAt ?? sibling?.abPairDecidedAt,
           let storedWinner = s.abPairWinnerSessionId ?? sibling?.abPairWinnerSessionId {
            return .alreadyDecided(winner: storedWinner, decidedAt: decidedAt)
        }
        if let decidedAt = s.abPairDecidedAt {
            return .alreadyDecided(winner: sessionId, decidedAt: decidedAt)
        }
        if let sibling, let decidedAt = sibling.abPairDecidedAt {
            return .alreadyDecided(winner: siblingId, decidedAt: decidedAt)
        }
        // First write wins: stamp both with the timestamp and stored winner.
        let projectedA = with(s, abPairDecidedAt: .some(when), abPairWinnerSessionId: .some(winner))
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: sessionId, session: projectedA)
        update(id: sessionId) { _ in projectedA }
        if let sib = session(id: siblingId) {
            let projectedB = with(sib, abPairDecidedAt: .some(when), abPairWinnerSessionId: .some(winner))
            try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: siblingId, session: projectedB)
            update(id: siblingId) { _ in projectedB }
        }
        return .decided(winner: winner, decidedAt: when)
    }

    public enum PickPairResult: Sendable {
        case decided(winner: UUID, decidedAt: Date)
        case alreadyDecided(winner: UUID, decidedAt: Date)
        case notPaired
        case invalidWinner
    }

    // MARK: - G12 multi-terminal

    public func addTerminalPane(sessionId: UUID, pane: TerminalPaneRef) async throws {
        guard let s = session(id: sessionId) else { return }
        var panes = s.terminalPanes.filter { $0.id != pane.id && $0.paneId != pane.paneId }
        if pane.isPrimary {
            panes = panes.map { existing in
                existing.isPrimary
                    ? TerminalPaneRef(
                        id: existing.id,
                        paneId: existing.paneId,
                        title: existing.title,
                        isPrimary: false,
                        createdAt: existing.createdAt
                    )
                    : existing
            }
        }
        panes.append(pane)
        let projected = with(s, terminalPanes: panes)
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: sessionId, session: projected)
        update(id: sessionId) { _ in projected }
    }

    public func replacePrimaryTerminalPane(sessionId: UUID, pane: TerminalPaneRef) async throws {
        guard let s = session(id: sessionId) else { return }
        let primary = TerminalPaneRef(id: pane.id, paneId: pane.paneId, title: pane.title, isPrimary: true)
        let panes = s.terminalPanes
            .filter { !$0.isPrimary && $0.id != pane.id && $0.paneId != pane.paneId }
            + [primary]
        let projected = with(s, terminalPanes: panes)
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: sessionId, session: projected)
        update(id: sessionId) { _ in projected }
    }

    public func removeTerminalPane(sessionId: UUID, paneRefId: UUID) async throws {
        guard let s = session(id: sessionId) else { return }
        let projected = with(s, terminalPanes: s.terminalPanes.filter { $0.id != paneRefId })
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: sessionId, session: projected)
        update(id: sessionId) { _ in projected }
    }

    /// v0.22.20: rename a terminal pane by id. Returns the updated
    /// `TerminalPaneRef` on success, nil when the session or pane id
    /// can't be resolved. Used by the AgentControlServer's
    /// `POST /sessions/:id/terminal-panes/:pane/rename` endpoint a
    /// parallel agent introduced — the registry side of that wire
    /// landed in this PR.
    @discardableResult
    public func renameTerminalPane(sessionId: UUID, paneRefId: UUID, title: String) async throws -> TerminalPaneRef? {
        guard let s = session(id: sessionId) else { return nil }
        let panes = s.terminalPanes.map { p -> TerminalPaneRef in
            guard p.id == paneRefId else { return p }
            return TerminalPaneRef(
                id: p.id,
                paneId: p.paneId,
                title: title,
                isPrimary: p.isPrimary,
                createdAt: p.createdAt
            )
        }
        let projected = with(s, terminalPanes: panes)
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: sessionId, session: projected)
        update(id: sessionId) { _ in projected }
        return session(id: sessionId)?.terminalPanes.first { $0.id == paneRefId }
    }

    // MARK: - G15 scheduled follow-ups

    public func addScheduledFollowUp(sessionId: UUID, followUp: ScheduledFollowUp) async throws {
        guard let s = session(id: sessionId) else { return }
        let projected = with(s, scheduledFollowUps: s.scheduledFollowUps + [followUp])
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: sessionId, session: projected)
        update(id: sessionId) { _ in projected }
    }

    public func removeScheduledFollowUp(sessionId: UUID, followUpId: UUID) async throws {
        guard let s = session(id: sessionId) else { return }
        let projected = with(s, scheduledFollowUps: s.scheduledFollowUps.filter { $0.id != followUpId })
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: sessionId, session: projected)
        update(id: sessionId) { _ in projected }
    }

    public func confirmScheduledFollowUp(
        sessionId: UUID,
        followUpId: UUID,
        confirmedBy: String = "user"
    ) async throws {
        guard let s = session(id: sessionId) else { return }
        let ups = s.scheduledFollowUps.map { f -> ScheduledFollowUp in
            guard f.id == followUpId else { return f }
            return ScheduledFollowUp(
                id: f.id,
                fireAt: f.fireAt,
                prompt: f.prompt,
                firedAt: f.firedAt,
                origin: .scheduledUserFollowUp,
                createdAt: f.createdAt,
                createdBy: confirmedBy,
                deliveryPolicy: .autonomousAfterRestart
            )
        }
        let projected = with(s, scheduledFollowUps: ups)
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: sessionId, session: projected)
        update(id: sessionId) { _ in projected }
    }

    public func markFollowUpFired(sessionId: UUID, followUpId: UUID, at firedAt: Date = Date()) async throws {
        guard let s = session(id: sessionId) else { return }
        let ups = s.scheduledFollowUps.map { f -> ScheduledFollowUp in
            if f.id == followUpId {
                return ScheduledFollowUp(
                    id: f.id,
                    fireAt: f.fireAt,
                    prompt: f.prompt,
                    firedAt: firedAt,
                    origin: f.origin,
                    createdAt: f.createdAt,
                    createdBy: f.createdBy,
                    deliveryPolicy: f.deliveryPolicy
                )
            }
            return f
        }
        let projected = with(s, scheduledFollowUps: ups)
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: sessionId, session: projected)
        update(id: sessionId) { _ in projected }
    }

    public func setInheritedContextSources(sessionId: UUID, sourceIds: [UUID]) async throws {
        guard let s = session(id: sessionId) else { return }
        let projected = with(s, inheritedContextSourceIds: sourceIds.isEmpty ? .some(nil) : .some(sourceIds))
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: sessionId, session: projected)
        update(id: sessionId) { _ in projected }
    }

    /// Mutate one session by id via a transform closure. Saves on every
    /// successful mutation. Single source of truth for v3-field propagation
    /// (T41 audit) for single-session updates; batched paths share `with(...)`
    /// below and perform their own coalesced save.
    private func update(id: UUID, _ transform: (AgentSession) -> AgentSession) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx] = transform(sessions[idx])
        save()
    }

    private func bumpEventSeq(id: UUID) {
        nextEventSeqBySession[id] = (nextEventSeqBySession[id] ?? 1) + 1
    }

    /// Re-emit the AgentSession with a swapped field set, preserving the rest.
    /// Bumps `lastEventAt`. Doesn't bump `lastEventSeq` unless caller passes
    /// one explicitly (those are cross-device events; local-state mutations
    /// like adding a pane don't need a new seq).
    ///
    /// Use `Optional<T>.some(nil)` to explicitly set a field to nil
    /// (Swift's "I really mean nil, don't fall back to the existing value")
    /// — e.g. `with(s, archivedAt: .some(nil))` to unarchive.
    private func with(
        _ s: AgentSession,
        status: AgentSessionStatus? = nil,
        agent: AgentKind? = nil,
        model: String?? = nil,
        planText: String?? = nil,
        approvedPlanText: String?? = nil,
        worktreePath: String?? = nil,
        provisioning: WorktreeProvisioningMetadata?? = nil,
        tmuxWindowId: String?? = nil,
        tmuxPaneId: String?? = nil,
        mode: SessionMode? = nil,
        archivedAt: Date?? = nil,
        terminalPanes: [TerminalPaneRef]? = nil,
        scheduledFollowUps: [ScheduledFollowUp]? = nil,
        effort: ReasoningEffort?? = nil,
        abPairSessionId: UUID?? = nil,
        abPairDecidedAt: Date?? = nil,
        abPairWinnerSessionId: UUID?? = nil,
        customName: String?? = nil,
        claudeSessionId: String?? = nil,
        codexChatThreadId: String?? = nil,
        runtimeCwd: String?? = nil,
        chatCwd: String?? = nil,
        runtimeBinding: SessionRuntimeBinding?? = nil,
        prMirrorState: PRMirrorState?? = nil,
        inheritedContextSourceIds: [UUID]?? = nil,
        ownsWorktree: Bool? = nil,
        envSetId: UUID?? = nil,
        envSetName: String?? = nil,
        lastEventSeq: UInt64? = nil,
        frontierGroupId: UUID?? = nil,
        frontierChildIndex: Int?? = nil,
        planProgress: PlanProgress?? = nil,
        customProviderId: String?? = nil,
        parentSessionId: UUID?? = nil,
        executionHostId: UUID?? = nil,
        executionHostLabel: String?? = nil,
        handoff: HandoffState?? = nil
    ) -> AgentSession {
        AgentSession(
            id: s.id,
            repoKey: s.repoKey,
            repoDisplayName: s.repoDisplayName,
            agent: agent ?? s.agent,
            model: Self.resolve(model, fallback: s.model),
            goal: s.goal,
            worktreePath: Self.resolve(worktreePath, fallback: s.worktreePath),
            provisioning: Self.resolve(provisioning, fallback: s.provisioning),
            tmuxWindowId: Self.resolve(tmuxWindowId, fallback: s.tmuxWindowId),
            tmuxPaneId: Self.resolve(tmuxPaneId, fallback: s.tmuxPaneId),
            status: status ?? s.status,
            planText: Self.resolve(planText, fallback: s.planText),
            approvedPlanText: Self.resolve(approvedPlanText, fallback: s.approvedPlanText),
            createdAt: s.createdAt,
            lastEventAt: Date(),
            lastEventSeq: lastEventSeq ?? s.lastEventSeq,
            mode: mode ?? s.mode,
            archivedAt: Self.resolve(archivedAt, fallback: s.archivedAt),
            terminalPanes: terminalPanes ?? s.terminalPanes,
            scheduledFollowUps: scheduledFollowUps ?? s.scheduledFollowUps,
            parentSessionId: Self.resolve(parentSessionId, fallback: s.parentSessionId),
            workspaceId: s.workspaceId,
            runtimeCwd: Self.resolve(runtimeCwd, fallback: s.runtimeCwd),
            chatCwd: Self.resolve(chatCwd, fallback: s.chatCwd),
            runtimeBinding: Self.resolve(runtimeBinding, fallback: s.runtimeBinding),
            prMirrorState: Self.resolve(prMirrorState, fallback: s.prMirrorState),
            effort: Self.resolve(effort, fallback: s.effort),
            abPairSessionId: Self.resolve(abPairSessionId, fallback: s.abPairSessionId),
            abPairDecidedAt: Self.resolve(abPairDecidedAt, fallback: s.abPairDecidedAt),
            abPairWinnerSessionId: Self.resolve(abPairWinnerSessionId, fallback: s.abPairWinnerSessionId),
            customName: Self.resolve(customName, fallback: s.customName),
            claudeSessionId: Self.resolve(claudeSessionId, fallback: s.claudeSessionId),
            // v0.8.0 schema v5 (chat-tab): preserve all chat fields
            // across mutations so an update to a chat session doesn't
            // silently convert it back to a code session.
            //
            // v0.23.9: frontierGroupId / frontierChildIndex now accept
            // an explicit override so handlePickFrontierWinner can
            // promote the winner out of the broadcast group (so
            // continue-from-winner flips the UI back to .solo without
            // any further send hitting archived losers).
            kind: s.kind,
            frontierGroupId: Self.resolve(frontierGroupId, fallback: s.frontierGroupId),
            frontierChildIndex: Self.resolve(frontierChildIndex, fallback: s.frontierChildIndex),
            codexChatBackend: s.codexChatBackend,
            codexChatThreadId: Self.resolve(codexChatThreadId, fallback: s.codexChatThreadId),
            deepResearch: s.deepResearch,
            planProgress: Self.resolve(planProgress, fallback: s.planProgress),
            providerInstanceId: s.providerInstanceId,
            inheritedContextSourceIds: Self.resolve(inheritedContextSourceIds, fallback: s.inheritedContextSourceIds),
            ownsWorktree: ownsWorktree ?? s.ownsWorktree,
            envSetId: Self.resolve(envSetId, fallback: s.envSetId),
            envSetName: Self.resolve(envSetName, fallback: s.envSetName),
            customProviderId: Self.resolve(customProviderId, fallback: s.customProviderId),
            executionHostId: Self.resolve(executionHostId, fallback: s.executionHostId),
            executionHostLabel: Self.resolve(executionHostLabel, fallback: s.executionHostLabel),
            handoff: Self.resolve(handoff, fallback: s.handoff)
        )
    }

    /// Wire v30: tag legacy sessions with the local execution host.
    private func backfillExecutionHostMetadata(_ loaded: [AgentSession]) -> [AgentSession] {
        let local = ExecutionHostStore.shared.localHost()
        return loaded.map { session in
            guard session.executionHostId == nil else { return session }
            return with(
                session,
                executionHostId: .some(local.id),
                executionHostLabel: .some(local.displayName)
            )
        }
    }

    /// v0.31.6 removed the tmux runtime, but Claude sessions persisted before
    /// that upgrade still carry `tmuxPaneId`/`tmuxWindowId`. Those dead fields
    /// make every write path (send, interrupt, permission/mode/model swap,
    /// autopilot, terminals) resolve the session to `.legacyRetired` and surface
    /// the "legacy_session_retired" toast. A Claude session is fully revivable,
    /// though: strip the stale pane metadata so it resolves to `.claudePty` and
    /// the next interaction transparently resume-or-spawns it via
    /// `claude --resume <claudeSessionId>` — no user action, no relaunch dance.
    /// Non-Claude legacy sessions have no cross-runtime resume path (the tmux →
    /// harness boundary), so they keep their pane metadata and stay retired.
    private func migratingRetiredClaudePanes(_ loaded: [AgentSession]) -> [AgentSession] {
        loaded.map { session in
            guard session.agent == .claude,
                  session.tmuxPaneId != nil || session.tmuxWindowId != nil
            else { return session }
            return with(session, tmuxWindowId: .some(nil), tmuxPaneId: .some(nil))
        }
    }

    private static func executionHostMetadata(
        executionHostId: UUID?,
        executionHostLabel: String?
    ) -> (id: UUID, label: String) {
        if let executionHostId {
            let label = executionHostLabel
                ?? ExecutionHostStore.shared.host(id: executionHostId)?.displayName
                ?? ExecutionHostStore.shared.localHost().displayName
            return (executionHostId, label)
        }
        let local = ExecutionHostStore.shared.localHost()
        return (local.id, local.displayName)
    }

    private static func reviewableApprovedPlanText(from session: AgentSession) -> String? {
        guard let raw = session.planText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return session.approvedPlanText }
        if session.agent == .codex,
           raw.hasPrefix("Codex is running in read-only plan mode.") {
            return session.approvedPlanText
        }
        return raw
    }

    private static func makeRuntimeBinding(
        agent: AgentKind,
        model: String?,
        codexBackend: CodexChatBackend?,
        chatVendor: ChatVendor? = nil,
        billingProvider: String? = nil
    ) -> SessionRuntimeBinding {
        let runtime = SessionRuntimeKind.inferred(
            agent: agent,
            codexBackend: codexBackend
        )
        let resolvedBillingProvider: String? = billingProvider ?? {
            switch agent {
            case .claude: return "claude"
            case .codex: return "codex"
            case .gemini: return "antigravity"
            case .opencode: return "opencode"
            case .cursor: return "cursor"
            case .grok: return "grok"
            case .unknown: return nil
            }
        }()
        let billingConfidence: BillingConfidence = {
            switch agent {
            case .opencode: return .providerReported
            case .cursor: return .unavailable
            case .grok: return .unavailable
            case .gemini: return .estimated
            case .claude, .codex: return .locallyPriced
            case .unknown: return .unavailable
            }
        }()
        return SessionRuntimeBinding(
            runtimeKind: runtime,
            externalSessionId: nil,
            projectId: nil,
            providerModelId: model,
            billingProvider: resolvedBillingProvider,
            billingConfidence: billingConfidence,
            metadata: chatVendor.map { ["chatVendor": $0.rawValue] } ?? [:]
        )
    }

    /// Wire v30: replace a session row wholesale (handoff metadata updates).
    public func replaceSession(_ session: AgentSession) async throws {
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: session.id, session: session)
        update(id: session.id) { _ in session }
    }

    /// Wire v30: update handoff phase on the source session during migration.
    public func updateHandoff(id: UUID, handoff: HandoffState?) async throws {
        guard let s = session(id: id) else { return }
        let projected = with(s, handoff: .some(handoff))
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
    }

    /// v0.5.4: set or clear the user-supplied display name. Empty /
    /// whitespace-only strings normalize to nil so the sidebar row +
    /// chat header fall back to `repoDisplayName`.
    public func rename(id: UUID, name: String?) async throws {
        guard let s = session(id: id) else { return }
        let normalized: String?? = {
            guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return .some(nil) }
            return .some(trimmed)
        }()
        let projected = with(s, customName: normalized)
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
    }

    /// Move every session bound to `oldWorkspacePath` onto `newWorktreePath`
    /// after a workspace/worktree rename. Updates cwd fields and provisioning
    /// metadata while preserving files-to-copy summaries.
    public func relocateWorktreeSessions(
        oldWorkspacePath: String,
        renameResult: WorktreeManager.RenamedWorktree
    ) async throws {
        let oldCanonical = WorkspaceKey.canonicalPath(oldWorkspacePath)
        let newCanonical = WorkspaceKey.canonicalPath(renameResult.newPath)
        guard oldCanonical != newCanonical
            || renameResult.oldBranchName != renameResult.newBranchName
        else { return }

        for session in sessions where sessionMatchesWorkspace(session, canonicalPath: oldCanonical) {
            let provisioningOverride: WorktreeProvisioningMetadata?? = {
                guard let prov = session.provisioning else { return nil }
                return .some(WorktreeProvisioningMetadata(
                    ownershipMarkerId: prov.ownershipMarkerId,
                    branchName: renameResult.newBranchName,
                    worktreePath: newCanonical,
                    storageRoot: prov.storageRoot,
                    projectSlug: prov.projectSlug,
                    workspaceSlug: renameResult.workspaceSlug,
                    branchAliasPath: renameResult.branchAliasPath,
                    filesToCopy: prov.filesToCopy,
                    createdAt: prov.createdAt
                ))
            }()
            let projected = with(
                session,
                worktreePath: relocatedPath(session.worktreePath, from: oldCanonical, to: newCanonical),
                provisioning: provisioningOverride,
                runtimeCwd: relocatedPath(session.runtimeCwd, from: oldCanonical, to: newCanonical),
                chatCwd: relocatedPath(session.chatCwd, from: oldCanonical, to: newCanonical)
            )
            try await writeReceipt(
                kind: .sessionMetadataUpdated,
                sessionId: session.id,
                session: projected
            )
            update(id: session.id) { _ in projected }
        }
    }

    private func sessionMatchesWorkspace(_ session: AgentSession, canonicalPath: String) -> Bool {
        let candidates = [session.worktreePath, session.runtimeCwd, session.chatCwd]
        return candidates.compactMap { $0 }
            .contains { WorkspaceKey.canonicalPath($0) == canonicalPath }
    }

    private func relocatedPath(_ path: String?, from old: String, to new: String) -> String?? {
        guard let path else { return nil }
        return WorkspaceKey.canonicalPath(path) == old ? .some(new) : nil
    }

    /// v6 (Track A): persist the Claude CLI session id for `--resume`. No-op if
    /// unchanged so the per-turn re-capture doesn't churn the registry / receipts.
    public func setClaudeSessionId(id: UUID, value: String?) async throws {
        guard let s = session(id: id), s.claudeSessionId != value else { return }
        let projected = with(s, claudeSessionId: .some(value))
        try await writeReceipt(kind: .sessionMetadataUpdated, sessionId: id, session: projected)
        update(id: id) { _ in projected }
    }

    private static func resolve<T>(_ override: T??, fallback: T?) -> T? {
        guard let override else { return fallback }
        return override
    }

    /// Delete a session record. Writes a `sessionDeleted` receipt with
    /// empty payload before purging the in-memory state; replay then
    /// removes the projection. If the F2 event store is on, also calls
    /// `OrchestrationEventStore.deleteSession(_:)` so the historical
    /// events + snapshot for this session are purged from the log (true
    /// GDPR / CCPA delete, not a tombstone — see codex #9).
    ///
    /// Order matters: the `.sessionDeleted` receipt MUST be appended
    /// before `deleteSession(...)` purges the log, otherwise the receipt
    /// itself would be wiped along with the history. Replay never sees
    /// the receipt for purged sessions on a future restart, which is
    /// fine — the projection ends up identical (no row for the session).
    public func delete(id: UUID) async throws {
        try await writeReceipt(kind: .sessionDeleted, sessionId: id, session: nil)
        if let store = eventStore {
            do {
                try await store.deleteSession(id.uuidString)
            } catch {
                // Privacy-delete failure on the historical events is
                // non-fatal — the receipt above marks the session as
                // deleted, so replay's projection is correct even if
                // the historical rows linger. Surface for telemetry.
                registryLogger.error("OrchestrationEventStore.deleteSession failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        sessions.removeAll { $0.id == id }
        HostRunMinuteStore.shared.sessionStopped(id)
        nextEventSeqBySession.removeValue(forKey: id)
        approvedAtBySession.removeValue(forKey: id)
        save()
    }

    // MARK: - Persistence (atomic write + schema migration)

    private struct StoreFile: Codable {
        var schemaVersion: Int
        var sessions: [AgentSession]
    }

    /// v3 (Sessions v2): adds optional `effort`, `abPairSessionId`,
    /// `abPairDecidedAt` to AgentSession.
    /// v4 (v0.5.4): adds optional `customName` (user-supplied display
    /// name). v1/v2/v3 files decode cleanly because the new keys
    /// default to nil in `AgentSession.init(from:)`. Downgrade path:
    /// older readers silently drop these fields.
    /// v5 (v0.8 Chat tab): adds optional `kind` (defaults to `.code`),
    /// `frontierGroupId`, `frontierChildIndex`, `codexChatBackend`,
    /// `codexChatThreadId`; flips `repoKey` to optional (chat sessions
    /// run in an empty chat-cwd, not a repo). v3/v4 files decode cleanly
    /// because all new keys are optional + decoder-tolerant. v4 readers
    /// reading v5 files see `kind` field ignored — chat sessions are
    /// just code sessions with a nil repoKey to v4, which crashes on the
    /// required-String decode. Mitigated by single-step v4→v5 bump (no
    /// intermediate "kind on v4" wire shape).
    /// v6 (Track A): adds optional `claudeSessionId` (the Claude CLI session id
    /// for `--resume`). v5 files decode cleanly (decodeIfPresent → nil).
    /// v7 (wire v30): adds optional `executionHostId`, `executionHostLabel`,
    /// `handoff` on AgentSession. Decoder-tolerant — v6 files load cleanly.
    private static let currentSchemaVersion = 7

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
            // Drop orphaned provisional sessions: a worktree-mode session with
            // no worktreePath was created optimistically by the "+" button but
            // never finished provisioning (app crashed / force-quit between
            // create and worktree-attach). Loading it would resolve the wrong
            // JSONL (effectiveCwd falls back to the repo root) and surface an
            // unrelated session's transcript. They have no worktree/pane to keep.
            let loaded = file.sessions.filter { s in
                !(s.mode == .worktree
                  && (s.worktreePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                  && s.tmuxPaneId == nil)
            }
            if loaded.count != file.sessions.count {
                registryLogger.info("Dropped \(file.sessions.count - loaded.count) orphaned provisional session(s) on load")
            }
            // Collapse duplicate session-id entries (a persistence race could
            // write the same id twice) — keep the first. A duplicate id otherwise
            // renders as two identical workspace tabs for one session.
            var seenSessionIds = Set<UUID>()
            let deduped = loaded.filter { seenSessionIds.insert($0.id).inserted }
            if deduped.count != loaded.count {
                registryLogger.warning("Collapsed \(loaded.count - deduped.count) duplicate-id session(s) on load")
            }
            // v0.31.6 removed tmux: revive Claude sessions persisted before that
            // upgrade by stripping their dead pane metadata (see
            // migratingRetiredClaudePanes). Strip BEFORE the host-metadata
            // backfill so the result carries both migrations.
            let retiredClaudePaneCount = deduped.filter {
                $0.agent == .claude && ($0.tmuxPaneId != nil || $0.tmuxWindowId != nil)
            }.count
            let migratedPanes = migratingRetiredClaudePanes(deduped)
            self.sessions = backfillExecutionHostMetadata(migratedPanes)
            // Restore per-session seq counters from the loaded data.
            for session in self.sessions {
                nextEventSeqBySession[session.id] = session.lastEventSeq + 1
            }
            // Persist the one-time strip so it doesn't re-run (and re-stamp
            // lastEventAt) on every launch.
            if retiredClaudePaneCount > 0 {
                registryLogger.info("Revived \(retiredClaudePaneCount) retired-tmux Claude session(s) as direct PTY")
                save()
            }
            registryLogger.info("Loaded \(self.sessions.count) sessions from \(self.storeURL.path, privacy: .public)")
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
