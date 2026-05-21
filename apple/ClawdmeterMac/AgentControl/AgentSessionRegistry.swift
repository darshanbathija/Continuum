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
        frontierChildIndex: Int? = nil
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
            effort: effort,
            kind: .chat,
            frontierGroupId: frontierGroupId,
            frontierChildIndex: frontierChildIndex,
            codexChatBackend: codexChatBackend,
            geminiBackend: geminiBackend,
            antigravityConversationId: antigravityConversationId,
            antigravityProjectId: antigravityProjectId
        )
        sessions.append(session)
        save()
        return session
    }

    /// v0.9 — read all sessions in a Frontier group, sorted by
    /// `frontierChildIndex`. Used by the Frontier WS snapshotter +
    /// HTTP handlers (send fan-out, retry-slot, pick-winner).
    public func frontierGroupChildren(groupId: UUID) -> [AgentSession] {
        sessions
            .filter { $0.frontierGroupId == groupId }
            .sorted { ($0.frontierChildIndex ?? Int.max) < ($1.frontierChildIndex ?? Int.max) }
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
            with(
                s,
                geminiBackend: .agentapi,
                antigravityConversationId: conversationId,
                antigravityProjectId: projectId
            )
        }
    }

    /// Update the persisted codex thread id for an SDK chat session after
    /// the first turn returns its `thread.started` event. Lets resume-
    /// after-evict in Phase 4.5 find the same server-side thread.
    public func setCodexChatThreadId(id: UUID, threadId: String) {
        update(id: id) { s in
            with(s, codexChatThreadId: threadId)
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
        update(id: id) { s in with(s, planText: planText) }
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
            with(s, model: model, effort: .some(effort ?? s.effort))
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
        lastEventSeq: UInt64? = nil
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
            createdAt: s.createdAt,
            lastEventAt: Date(),
            lastEventSeq: lastEventSeq ?? s.lastEventSeq,
            mode: mode ?? s.mode,
            archivedAt: Self.resolve(archivedAt, fallback: s.archivedAt),
            terminalPanes: terminalPanes ?? s.terminalPanes,
            scheduledFollowUps: scheduledFollowUps ?? s.scheduledFollowUps,
            parentSessionId: s.parentSessionId,
            effort: Self.resolve(effort, fallback: s.effort),
            abPairSessionId: Self.resolve(abPairSessionId, fallback: s.abPairSessionId),
            abPairDecidedAt: Self.resolve(abPairDecidedAt, fallback: s.abPairDecidedAt),
            customName: Self.resolve(customName, fallback: s.customName),
            // v0.8.0 schema v5 (chat-tab): preserve all chat fields
            // across mutations so an update to a chat session doesn't
            // silently convert it back to a code session.
            kind: s.kind,
            frontierGroupId: s.frontierGroupId,
            frontierChildIndex: s.frontierChildIndex,
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
            antigravityProjectId: Self.resolve(antigravityProjectId, fallback: s.antigravityProjectId)
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
