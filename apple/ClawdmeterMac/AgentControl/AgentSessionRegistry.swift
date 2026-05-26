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
/// helper so new fields (`effort`, `abPairSessionId`, `abPairDecidedAt`)
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

    /// F2 — orchestration event store. Opt-in via
    /// `FeatureFlags.orchestrationEventStore`. When set, the registry can
    /// (a) seed itself from event replay on init and (b) write a receipt
    /// before every mutation. This PR ships the store + the replay-on-init
    /// path; per-mutation write-ahead is wired in the follow-up F2-wire PR
    /// (strangler-fig per D23) so we can A/B rollback by flipping the flag
    /// default back to `false`.
    ///
    /// `nil` when the flag is off — legacy `sessions.json` snapshot path
    /// stays unchanged.
    private let eventStore: OrchestrationEventStore?

    public init(
        storeURL: URL = AgentSessionRegistry.defaultStoreURL(),
        eventStore: OrchestrationEventStore? = nil
    ) {
        self.storeURL = storeURL
        // Respect injected store (tests), else honor the feature flag.
        // Wrapping in `try?` so a corrupt-recovery on init never crashes
        // the daemon: store falls back to nil → legacy path.
        if let injected = eventStore {
            self.eventStore = injected
        } else if FeatureFlags.orchestrationEventStore {
            self.eventStore = try? OrchestrationEventStore()
        } else {
            self.eventStore = nil
        }
        load()
        // F2 replay-on-init: if we opened an event store AND the JSON
        // snapshot was empty (cold start on a fresh install where the
        // flag is on) AND the event log has anything, seed state from
        // replay. The JSON snapshot is the source of truth for now —
        // events are write-ahead, the snapshot is the projection. The
        // wire PR will flip this so the event log is the source of
        // truth and the snapshot becomes a cache.
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

    // MARK: - F2 event store hooks (strangler-fig)

    /// Public write-ahead hook for the F2-wire PR. Today no built-in
    /// mutation methods call this — wire-up lands in the follow-up so the
    /// foundation PR stays focused on the store + replay path. External
    /// callers (the daemon's request handlers) MAY call it directly if
    /// they want the write-ahead receipt without waiting for wire-up.
    ///
    /// No-op when the feature flag is off (eventStore == nil).
    public func recordCommand(_ command: OrchestrationCommand) {
        guard let store = eventStore else { return }
        Task {
            do {
                _ = try await store.append(command)
            } catch {
                registryLogger.error("OrchestrationEventStore.append failed: \(error.localizedDescription, privacy: .public)")
            }
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
        // P0 fix (review of PR #146): the replay Task MUST run off MainActor.
        // The original code used `Task { ... }` here which inherits MainActor
        // isolation. Combined with `sema.wait()` blocking the MainActor below,
        // that deadlocked at startup whenever the event log was non-empty —
        // the MainActor task body could not resume because MainActor was
        // parked on the semaphore. Use `Task.detached` so the body runs on
        // a cooperative thread; the actor isolation on `store.loadAll(...)`
        // still serializes the sqlite work safely.
        let replayed = Self.runReplayBlocking(store: store)
        guard let replayed, !replayed.isEmpty else { return }
        self.sessions = replayed
        for s in replayed {
            nextEventSeqBySession[s.id] = s.lastEventSeq + 1
        }
        registryLogger.info("Seeded \(replayed.count) sessions from OrchestrationEventStore replay")
    }

    /// Synchronously run the event-store replay from the MainActor `init`
    /// body. Uses a detached Task so the replay body does NOT inherit
    /// MainActor isolation — that is what makes the surrounding
    /// `DispatchSemaphore.wait()` safe (a MainActor-isolated task body
    /// would deadlock because resume requires the MainActor that we have
    /// parked on the semaphore).
    ///
    /// The replay is bounded by the codex #9 perf gate (10k events <500ms),
    /// so blocking init for the duration is acceptable.
    private nonisolated static func runReplayBlocking(store: OrchestrationEventStore) -> [AgentSession]? {
        let sema = DispatchSemaphore(value: 0)
        // Sendable wrapper for the result so we can write from the
        // detached task and read after the semaphore wait.
        final class Box: @unchecked Sendable {
            var value: [AgentSession]?
        }
        let box = Box()
        Task.detached {
            defer { sema.signal() }
            do {
                let rows = try await store.loadAll(includeSnapshots: true)
                guard !rows.isEmpty else { return }
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
                box.value = Array(projection.values)
            } catch {
                registryLogger.error("OrchestrationEventStore replay failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        sema.wait()
        return box.value
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
        planMode: Bool,
        mode: SessionMode = .local,
        parentSessionId: UUID? = nil,
        effort: ReasoningEffort? = nil,
        abPairSessionId: UUID? = nil,
        // v0.8.0 agy-migration — Gemini sessions spawned through
        // Antigravity 2's agentapi don't have a tmux pane (tmuxWindowId
        // + tmuxPaneId both nil); they carry the transport tag +
        // conversation UUID instead so SessionChatStore can attach to
        // the right SQLite DB.
        geminiBackend: GeminiBackend? = nil,
        antigravityConversationId: UUID? = nil,
        antigravityProjectId: String? = nil
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
            lastEventSeq: 1,
            mode: mode,
            parentSessionId: parentSessionId,
            runtimeCwd: worktreePath ?? repoKey,
            runtimeBinding: Self.makeRuntimeBinding(
                agent: agent,
                model: model,
                codexBackend: nil,
                geminiBackend: geminiBackend,
                antigravityConversationId: antigravityConversationId,
                antigravityProjectId: antigravityProjectId
            ),
            effort: effort,
            abPairSessionId: abPairSessionId,
            geminiBackend: geminiBackend,
            antigravityConversationId: antigravityConversationId,
            antigravityProjectId: antigravityProjectId
        )
        sessions.append(session)
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
        geminiBackend: GeminiBackend? = nil,
        antigravityConversationId: UUID? = nil,
        antigravityProjectId: String? = nil,
        frontierGroupId: UUID? = nil,
        frontierChildIndex: Int? = nil,
        deepResearch: Bool = false,
        chatVendor: ChatVendor? = nil,
        billingProvider: String? = nil
    ) -> AgentSession {
        let id = UUID()
        let now = Date()
        nextEventSeqBySession[id] = 1
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
                geminiBackend: geminiBackend,
                antigravityConversationId: antigravityConversationId,
                antigravityProjectId: antigravityProjectId,
                chatVendor: chatVendor,
                billingProvider: billingProvider
            ),
            effort: effort,
            kind: .chat,
            frontierGroupId: frontierGroupId,
            frontierChildIndex: frontierChildIndex,
            codexChatBackend: codexChatBackend,
            geminiBackend: geminiBackend,
            antigravityConversationId: antigravityConversationId,
            antigravityProjectId: antigravityProjectId,
            deepResearch: deepResearch
        )
        sessions.append(session)
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
    public func clearFrontierGroupBinding(id: UUID) {
        update(id: id) { s in
            with(
                s,
                frontierGroupId: .some(nil),
                frontierChildIndex: .some(nil)
            )
        }
    }

    /// v0.9 — patch the agentapi binding fields on an existing chat
    /// session after the daemon's POST /chat-sessions handler kicks off
    /// agentapi `new-conversation`. Two-phase create because the
    /// chat-cwd needs to exist before we know the conversation id, but
    /// the session record needs to exist before we can store the
    /// chat-cwd. Idempotent.
    public func setAntigravityChatBinding(
        id: UUID,
        conversationId: UUID,
        projectId: String
    ) {
        update(id: id) { s in
            let binding = (s.runtimeBinding ?? Self.makeRuntimeBinding(
                agent: s.agent,
                model: s.model,
                codexBackend: s.codexChatBackend,
                geminiBackend: .agentapi,
                antigravityConversationId: conversationId,
                antigravityProjectId: projectId
            )).updating(
                externalSessionId: .some(conversationId.uuidString),
                projectId: .some(projectId)
            )
            return with(
                s,
                geminiBackend: .agentapi,
                antigravityConversationId: conversationId,
                antigravityProjectId: projectId,
                runtimeBinding: binding
            )
        }
    }

    /// Update the persisted codex thread id for an SDK chat session after
    /// the first turn returns its `thread.started` event. Lets resume-
    /// after-evict in Phase 4.5 find the same server-side thread.
    public func setCodexChatThreadId(id: UUID, threadId: String) {
        update(id: id) { s in
            let binding = (s.runtimeBinding ?? Self.makeRuntimeBinding(
                agent: s.agent,
                model: s.model,
                codexBackend: s.codexChatBackend,
                geminiBackend: s.geminiBackend,
                antigravityConversationId: s.antigravityConversationId,
                antigravityProjectId: s.antigravityProjectId
            )).updating(externalThreadId: .some(threadId))
            return with(s, codexChatThreadId: threadId, runtimeBinding: binding)
        }
    }

    public func session(id: UUID) -> AgentSession? {
        sessions.first { $0.id == id }
    }

    /// Per-session monotonic event seq counter. Used by AgentEventStream.
    public func nextEventSeq(for sessionId: UUID) -> UInt64 {
        let next = (nextEventSeqBySession[sessionId] ?? 0) + 1
        nextEventSeqBySession[sessionId] = next
        return next
    }

    public func updateStatus(id: UUID, status: AgentSessionStatus) {
        bumpEventSeq(id: id)
        update(id: id) { s in
            with(s, status: status, lastEventSeq: s.lastEventSeq + 1)
        }
    }

    public func setPlanText(id: UUID, planText: String) {
        guard let current = session(id: id), current.planText != planText else { return }
        bumpEventSeq(id: id)
        update(id: id) { s in
            with(s, planText: planText, lastEventSeq: s.lastEventSeq + 1)
        }
    }

    public func markPlanApproved(id: UUID) {
        guard let current = session(id: id) else { return }
        let approved = Self.reviewableApprovedPlanText(from: current)
        guard current.planText != nil || current.approvedPlanText != approved else { return }
        bumpEventSeq(id: id)
        // Stamp approvedAt so subsequent `PlanProgressTracker` recomputes
        // can filter out the plan-emission assistant message — the message
        // whose `at` is at-or-before this stamp is the one that contains
        // the entire plan verbatim, and matching against it would
        // self-complete every step.
        let approvedAt = Date()
        approvedAtBySession[id] = approvedAt
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
        update(id: id) { s in
            with(
                s,
                planText: .some(nil),
                approvedPlanText: approved,
                lastEventSeq: s.lastEventSeq + 1,
                planProgress: .some(initialProgress)
            )
        }
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
    public func setPlanProgress(id: UUID, progress: PlanProgress?) {
        guard let current = session(id: id) else { return }
        guard current.planProgress != progress else { return }
        bumpEventSeq(id: id)
        update(id: id) { s in
            with(s, lastEventSeq: s.lastEventSeq + 1, planProgress: .some(progress))
        }
    }

    /// Update the in-place cwd/worktree metadata (used when the user switches
    /// the mode picker on a live session and we re-spawn the agent in a new
    /// directory).
    public func updateRuntime(
        id: UUID,
        worktreePath: String?,
        tmuxWindowId: String?,
        tmuxPaneId: String?,
        mode: SessionMode
    ) {
        update(id: id) { s in
            with(
                s,
                worktreePath: worktreePath,
                tmuxWindowId: tmuxWindowId,
                tmuxPaneId: tmuxPaneId,
                mode: mode
            )
        }
    }

    /// Sessions v2: swap model on a live session (Phase 0). `effort: nil`
    /// means "leave effort unchanged" — pass the existing value through so
    /// `with()`'s double-optional override semantics don't null it out.
    public func setModel(id: UUID, model: String, effort: ReasoningEffort?) {
        update(id: id) { s in
            let binding = (s.runtimeBinding ?? Self.makeRuntimeBinding(
                agent: s.agent,
                model: model,
                codexBackend: s.codexChatBackend,
                geminiBackend: s.geminiBackend,
                antigravityConversationId: s.antigravityConversationId,
                antigravityProjectId: s.antigravityProjectId
            )).updating(providerModelId: .some(model))
            return with(
                s,
                model: model,
                effort: .some(effort ?? s.effort),
                runtimeBinding: binding
            )
        }
    }

    /// Sessions v2: swap effort on a live session (Phase 0).
    public func setEffort(id: UUID, effort: ReasoningEffort) {
        update(id: id) { s in with(s, effort: effort) }
    }

    /// Sessions v2: change plan mode mid-session (status flips to planning).
    public func setPlanMode(id: UUID, planMode: Bool) {
        update(id: id) { s in
            with(s, status: planMode ? .planning : .running)
        }
    }

    /// Archive (hide from default sidebar). Reversible via `unarchive(id:)`.
    /// If the session is one half of an A/B pair, the sibling's
    /// `abPairSessionId` is cleared automatically per D16.
    public func archive(id: UUID, at date: Date = Date()) {
        guard let s = session(id: id) else { return }
        update(id: id) { s in with(s, archivedAt: date) }
        // D16: promote sibling to standalone with banner.
        if let siblingId = s.abPairSessionId {
            update(id: siblingId) { sib in
                with(sib, abPairSessionId: .some(nil))
            }
        }
    }

    public func unarchive(id: UUID) {
        update(id: id) { s in with(s, archivedAt: .some(nil)) }
    }

    // MARK: - A/B pair operations (Phase 7 + E3 atomic CAS)

    /// Link two existing sessions as an A/B pair. Idempotent: re-linking
    /// the same pair is a no-op.
    public func linkABPair(_ a: UUID, _ b: UUID) {
        update(id: a) { s in with(s, abPairSessionId: .some(b)) }
        update(id: b) { s in with(s, abPairSessionId: .some(a)) }
    }

    /// Atomic compare-and-set on A/B pair winner-pick. Returns the resolved
    /// decision (existing if already decided, new otherwise) or nil if the
    /// session id is unknown.
    ///
    /// E3: first request locks `abPairDecidedAt`; subsequent requests see
    /// the existing decision and the caller responds 409.
    public func pickPairWinner(sessionId: UUID, winner: UUID, at when: Date = Date()) -> PickPairResult? {
        guard let s = session(id: sessionId) else { return nil }
        guard let siblingId = s.abPairSessionId else {
            return .notPaired
        }
        // Validate that the winner is one of the pair members.
        guard winner == sessionId || winner == siblingId else {
            return .invalidWinner
        }
        // Check both members for an existing decision (whichever was hit first).
        if let decidedAt = s.abPairDecidedAt {
            // Already decided — return that decision.
            return .alreadyDecided(winner: s.abPairSessionId == winner ? siblingId : sessionId, decidedAt: decidedAt)
        }
        if let sibling = session(id: siblingId), let decidedAt = sibling.abPairDecidedAt {
            return .alreadyDecided(winner: sibling.abPairSessionId == winner ? sessionId : siblingId, decidedAt: decidedAt)
        }
        // First write wins: stamp both with the timestamp.
        update(id: sessionId) { s in with(s, abPairDecidedAt: .some(when)) }
        update(id: siblingId) { s in with(s, abPairDecidedAt: .some(when)) }
        return .decided(winner: winner, decidedAt: when)
    }

    public enum PickPairResult: Sendable {
        case decided(winner: UUID, decidedAt: Date)
        case alreadyDecided(winner: UUID, decidedAt: Date)
        case notPaired
        case invalidWinner
    }

    // MARK: - G12 multi-terminal

    public func addTerminalPane(sessionId: UUID, pane: TerminalPaneRef) {
        update(id: sessionId) { s in
            var panes = s.terminalPanes
            panes.append(pane)
            return with(s, terminalPanes: panes)
        }
    }

    public func removeTerminalPane(sessionId: UUID, paneRefId: UUID) {
        update(id: sessionId) { s in
            with(s, terminalPanes: s.terminalPanes.filter { $0.id != paneRefId })
        }
    }

    /// v0.22.20: rename a terminal pane by id. Returns the updated
    /// `TerminalPaneRef` on success, nil when the session or pane id
    /// can't be resolved. Used by the AgentControlServer's
    /// `POST /sessions/:id/terminal-panes/:pane/rename` endpoint a
    /// parallel agent introduced — the registry side of that wire
    /// landed in this PR.
    @discardableResult
    public func renameTerminalPane(sessionId: UUID, paneRefId: UUID, title: String) -> TerminalPaneRef? {
        update(id: sessionId) { s in
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
            return with(s, terminalPanes: panes)
        }
        return session(id: sessionId)?.terminalPanes.first { $0.id == paneRefId }
    }

    // MARK: - G15 scheduled follow-ups

    public func addScheduledFollowUp(sessionId: UUID, followUp: ScheduledFollowUp) {
        update(id: sessionId) { s in
            with(s, scheduledFollowUps: s.scheduledFollowUps + [followUp])
        }
    }

    public func removeScheduledFollowUp(sessionId: UUID, followUpId: UUID) {
        update(id: sessionId) { s in
            with(s, scheduledFollowUps: s.scheduledFollowUps.filter { $0.id != followUpId })
        }
    }

    public func markFollowUpFired(sessionId: UUID, followUpId: UUID, at firedAt: Date = Date()) {
        update(id: sessionId) { s in
            let ups = s.scheduledFollowUps.map { f -> ScheduledFollowUp in
                if f.id == followUpId {
                    return ScheduledFollowUp(id: f.id, fireAt: f.fireAt, prompt: f.prompt, firedAt: firedAt)
                }
                return f
            }
            return with(s, scheduledFollowUps: ups)
        }
    }

    /// Mutate one session by id via a transform closure. Saves on every
    /// successful mutation. Single source of truth for v3-field propagation
    /// (T41 audit) — every public mutation goes through here, so adding a
    /// new field is a one-line change to `with(...)` below.
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
        model: String?? = nil,
        planText: String?? = nil,
        approvedPlanText: String?? = nil,
        worktreePath: String?? = nil,
        tmuxWindowId: String?? = nil,
        tmuxPaneId: String?? = nil,
        mode: SessionMode? = nil,
        archivedAt: Date?? = nil,
        terminalPanes: [TerminalPaneRef]? = nil,
        scheduledFollowUps: [ScheduledFollowUp]? = nil,
        effort: ReasoningEffort?? = nil,
        abPairSessionId: UUID?? = nil,
        abPairDecidedAt: Date?? = nil,
        customName: String?? = nil,
        codexChatThreadId: String?? = nil,
        geminiBackend: GeminiBackend?? = nil,
        antigravityConversationId: UUID?? = nil,
        antigravityProjectId: String?? = nil,
        runtimeCwd: String?? = nil,
        chatCwd: String?? = nil,
        runtimeBinding: SessionRuntimeBinding?? = nil,
        prMirrorState: PRMirrorState?? = nil,
        lastEventSeq: UInt64? = nil,
        frontierGroupId: UUID?? = nil,
        frontierChildIndex: Int?? = nil,
        planProgress: PlanProgress?? = nil
    ) -> AgentSession {
        AgentSession(
            id: s.id,
            repoKey: s.repoKey,
            repoDisplayName: s.repoDisplayName,
            agent: s.agent,
            model: Self.resolve(model, fallback: s.model),
            goal: s.goal,
            worktreePath: Self.resolve(worktreePath, fallback: s.worktreePath),
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
            parentSessionId: s.parentSessionId,
            workspaceId: s.workspaceId,
            runtimeCwd: Self.resolve(runtimeCwd, fallback: s.runtimeCwd),
            chatCwd: Self.resolve(chatCwd, fallback: s.chatCwd),
            runtimeBinding: Self.resolve(runtimeBinding, fallback: s.runtimeBinding),
            prMirrorState: Self.resolve(prMirrorState, fallback: s.prMirrorState),
            effort: Self.resolve(effort, fallback: s.effort),
            abPairSessionId: Self.resolve(abPairSessionId, fallback: s.abPairSessionId),
            abPairDecidedAt: Self.resolve(abPairDecidedAt, fallback: s.abPairDecidedAt),
            customName: Self.resolve(customName, fallback: s.customName),
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
            // v0.8.1 schema v6 (agy-migration): geminiBackend +
            // antigravityConversationId usually only get set at
            // create-time, but v0.9 adds a two-phase bind via
            // setAntigravityChatBinding so chat-sessions can promote
            // from a placeholder record to a real agentapi binding once
            // the daemon's POST /chat-sessions has run new-conversation.
            // Resolve-with-fallback so non-binding mutations preserve.
            geminiBackend: Self.resolve(geminiBackend, fallback: s.geminiBackend),
            antigravityConversationId: Self.resolve(antigravityConversationId, fallback: s.antigravityConversationId),
            antigravityProjectId: Self.resolve(antigravityProjectId, fallback: s.antigravityProjectId),
            deepResearch: s.deepResearch,
            planProgress: Self.resolve(planProgress, fallback: s.planProgress)
        )
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
        geminiBackend: GeminiBackend?,
        antigravityConversationId: UUID?,
        antigravityProjectId: String?,
        chatVendor: ChatVendor? = nil,
        billingProvider: String? = nil
    ) -> SessionRuntimeBinding {
        let runtime = SessionRuntimeKind.inferred(
            agent: agent,
            codexBackend: codexBackend,
            geminiBackend: geminiBackend
        )
        let resolvedBillingProvider: String? = billingProvider ?? {
            switch agent {
            case .claude: return "claude"
            case .codex: return "codex"
            case .gemini: return "antigravity"
            case .opencode: return "opencode"
            case .cursor: return "cursor"
            case .unknown: return nil
            }
        }()
        let billingConfidence: BillingConfidence = {
            switch agent {
            case .opencode: return .providerReported
            case .cursor: return .unavailable
            case .gemini: return .estimated
            case .claude, .codex: return .locallyPriced
            case .unknown: return .unavailable
            }
        }()
        return SessionRuntimeBinding(
            runtimeKind: runtime,
            externalSessionId: antigravityConversationId?.uuidString,
            projectId: antigravityProjectId,
            providerModelId: model,
            billingProvider: resolvedBillingProvider,
            billingConfidence: billingConfidence,
            metadata: chatVendor.map { ["chatVendor": $0.rawValue] } ?? [:]
        )
    }

    /// v0.5.4: set or clear the user-supplied display name. Empty /
    /// whitespace-only strings normalize to nil so the sidebar row +
    /// chat header fall back to `repoDisplayName`.
    public func rename(id: UUID, name: String?) {
        let normalized: String?? = {
            guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return .some(nil) }
            return .some(trimmed)
        }()
        update(id: id) { s in with(s, customName: normalized) }
    }

    private static func resolve<T>(_ override: T??, fallback: T?) -> T? {
        guard let override else { return fallback }
        return override
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
    private static let currentSchemaVersion = 5

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
