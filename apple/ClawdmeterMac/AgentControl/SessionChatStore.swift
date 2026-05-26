import Foundation
import ClawdmeterShared
import OSLog
import os.signpost

private let chatLogger = Logger(subsystem: "com.clawdmeter.mac", category: "ChatStore")

private let chatRecentMessageLimit = 200
private let chatInitialTailByteBudget: UInt64 = 2 * 1024 * 1024

/// Perf-overhaul P0/T14 instrumentation. Always-on; OSSignposts are free
/// at runtime when no Instruments trace is attached. Captures the
/// session-open → first-paint window so we can prove the perf wins in
/// future refactors.
let chatPerfLog = OSLog(subsystem: "com.clawdmeter.mac", category: "Performance")

/// Per-session chat-style event store. Tails the session's JSONL, parses
/// each line into a typed `ChatMessage`, and publishes the array for the
/// SwiftUI chat view to render.
///
/// What we parse (Claude Code JSONL shape):
/// - `type=user`: a `message.content` string OR an array containing
///   `tool_result` blocks (for tool returns) and/or `text` blocks.
/// - `type=assistant`: `message.content` is an array of `text` /
///   `tool_use` blocks. `tool_use` carries `name`+`input`.
/// - `type=attachment` / `type=queue-operation` / `type=last-prompt`:
///   skipped (not user-visible chat).
///
/// The store accumulates messages in arrival order. Live updates via the
/// JSONLTail's DispatchSource fire `applyLine` on the main actor so the
/// SwiftUI view re-renders incrementally.
@MainActor
public final class SessionChatStore: ObservableObject {

    /// `ChatMessage` is now the Shared value type (T1 extraction). Keeping
    /// the SessionChatStore.ChatMessage alias preserves the existing
    /// `[SessionChatStore.ChatMessage]` API used by PRMirror and views.
    public typealias ChatMessage = ClawdmeterShared.ChatMessage

    /// Snapshot of all derived chat state — items array (with ToolPair
    /// runs), plus future per-pane caches added in T8/T9. Published as
    /// a single value so SwiftUI's Combine fan-out is one invalidation
    /// per frame instead of N per message. Codex tension #4 baked in:
    /// consistency by construction.
    public struct ChatSnapshot: Sendable, Equatable {
        public let items: [ChatItem]
        /// v0.5.3: raw chronologically-sorted ChatMessage list, exposed
        /// for the daemon's `/transcript` endpoint to serve through the
        /// `DaemonChatStoreRegistry`'s path-based cache (same caching
        /// pattern as `/chat-snapshot`, no per-request reparse). The
        /// `items` array above is derived from this list via
        /// `ChatItemBuilder`; both fields publish together so callers
        /// see a consistent snapshot.
        public let messages: [ChatMessage]
        public let planSteps: [PlanStep]
        public let sourceEntries: [SourceEntry]
        public let artifactEntries: [ArtifactEntry]
        /// v0.7.8: latest `todo_list` event payload from the Codex SDK
        /// stream. Empty for non-SDK / non-Codex sessions. Drives the
        /// Mac CodexPlanPane + iOS CodexPlanView + Watch
        /// CodexTaskComplication parity surfaces.
        public let codexTodos: [CodexTodoItem]
        /// Fresh input tokens (`message.usage.input_tokens`). Held
        /// separately from cache_creation and cache_read so the cost
        /// estimator can apply the right rate per category — Sonnet's
        /// cache_read rate is 10x cheaper than fresh input.
        public let totalInputTokens: Int
        public let totalOutputTokens: Int
        public let totalCacheCreationTokens: Int
        public let totalCacheReadTokens: Int
        /// MOST-RECENT turn's input/cache tokens — NOT cumulative. The sum
        /// `lastInputTokens + lastCacheReadTokens + lastCacheCreationTokens`
        /// is the model's working-memory size for the next turn, which is
        /// what the composer's "context window" meter should display. The
        /// cumulative `total*` values double-count cache reads across every
        /// turn and grow to billions for long sessions.
        public let lastInputTokens: Int
        public let lastOutputTokens: Int
        public let lastCacheCreationTokens: Int
        public let lastCacheReadTokens: Int
        /// Last assistant message's `message.model` field. We use the
        /// latest one because users sometimes switch mid-session via
        /// `/model`; the most recent tokens are billed at the most
        /// recent model's rates. Nil for sessions with no Claude
        /// assistant turns ingested yet.
        public let modelHint: String?
        /// Timestamp of the latest ingested message. Drives the
        /// "thinking" indicator — the chat shows the running animation
        /// when the file has been touched within the activity window.
        public let lastEventAt: Date?
        /// Monotonic counter that bumps each time the snapshot updates.
        /// View code uses this for `.onChange` triggers instead of
        /// `items.last?.id`, which would change object identity per render.
        public let updateCounter: UInt64
        /// v0.23 (Chat V2): explicit per-turn lifecycle. Updated by the
        /// daemon's ingestors (JSONLTail for Claude `result`,
        /// CodexSDKEventIngestor for `turn.completed`, AntigravityChatIngestor
        /// for `chunk_done`). Drives the V2 status strip's stopwatch
        /// clamp + Stop↔Send transition. Defaults to `.idle` on
        /// legacy snapshots.
        public let currentTurnState: TurnState

        public init(
            items: [ChatItem],
            messages: [ChatMessage] = [],
            planSteps: [PlanStep] = [],
            sourceEntries: [SourceEntry] = [],
            artifactEntries: [ArtifactEntry] = [],
            codexTodos: [CodexTodoItem] = [],
            totalInputTokens: Int = 0,
            totalOutputTokens: Int = 0,
            totalCacheCreationTokens: Int = 0,
            totalCacheReadTokens: Int = 0,
            lastInputTokens: Int = 0,
            lastOutputTokens: Int = 0,
            lastCacheCreationTokens: Int = 0,
            lastCacheReadTokens: Int = 0,
            modelHint: String? = nil,
            lastEventAt: Date? = nil,
            updateCounter: UInt64,
            currentTurnState: TurnState = .idle
        ) {
            self.items = items
            self.messages = messages
            self.planSteps = planSteps
            self.sourceEntries = sourceEntries
            self.artifactEntries = artifactEntries
            self.codexTodos = codexTodos
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.totalCacheCreationTokens = totalCacheCreationTokens
            self.totalCacheReadTokens = totalCacheReadTokens
            self.lastInputTokens = lastInputTokens
            self.lastOutputTokens = lastOutputTokens
            self.lastCacheCreationTokens = lastCacheCreationTokens
            self.lastCacheReadTokens = lastCacheReadTokens
            self.modelHint = modelHint
            self.lastEventAt = lastEventAt
            self.updateCounter = updateCounter
            self.currentTurnState = currentTurnState
        }

        public static let empty = ChatSnapshot(items: [], updateCounter: 0)

        /// Headline tokens for the activity strip — sum of all four
        /// categories. Matches the analytics layer's `TokenTotals.totalTokens`.
        public var totalTokens: Int {
            totalInputTokens + totalOutputTokens
                + totalCacheCreationTokens + totalCacheReadTokens
        }

        /// Single-turn working-memory size — what the model actually sees
        /// in its prompt for the next turn. Used by the composer's context
        /// window meter (the cumulative totals overstate by Nx where N is
        /// the turn count because cache reads are re-counted every turn).
        public var contextWindowUsedTokens: Int {
            lastInputTokens + lastCacheCreationTokens + lastCacheReadTokens
        }

        /// v0.29.4: start-of-current-turn timestamp for the live activity
        /// pill. The pill used to take `lastEventAt` (most recent ANY
        /// event), so reopening a long-running session showed "0.0s ·
        /// thinking…" and counted up from the click — wrong: it should
        /// reflect how long the model has been working on the current
        /// task. The most recent `.userText` message's timestamp marks
        /// the beginning of the current turn; the agent has been working
        /// ever since. Once a turn settles (no new events for the activity
        /// window) the indicator hides itself, so this property doesn't
        /// need to clamp on turn-complete — `isActive` does.
        public var currentTurnStartedAt: Date? {
            messages.last(where: { $0.kind == .userText })?.at
        }
    }

    /// A13 — alias to the Shared value type that owns the state machine.
    /// Lives in `ClawdmeterShared` so its behaviour is unit-testable from
    /// the SwiftPM test target; this alias keeps `SessionChatStore.PendingMessage`
    /// addressable from existing Mac call sites without a wide-scale import
    /// rewrite.
    public typealias PendingMessage = OptimisticPendingMessage

    @Published public private(set) var snapshot: ChatSnapshot = .empty
    /// Back-compat: views that still call `store.messages` keep working.
    /// Derived lazily from `snapshot.items` — was previously a parallel
    /// `@Published` rebuilt on every 16ms commit (allocating a fresh
    /// flat array on the main thread). With the snapshot now driving
    /// all view invalidations, the read sites (PRMirror.findPRURL,
    /// SessionsModel.filter search, PoppedChatThread ForEach) re-flatten
    /// only when they actually consume it. ObservableObject notification
    /// happens via `$snapshot` so subscribers still see updates.
    public var messages: [ChatMessage] {
        Self.flattenMessages(from: snapshot.items)
    }
    @Published public private(set) var isLoading: Bool = true
    @Published public private(set) var hasOlderHistory: Bool = false

    /// v0.8 QA: a CLI permission prompt awaiting user input. The Mac UI
    /// renders this as an AskUserQuestion-style card; on user click the
    /// daemon dispatches the corresponding keys to the CLI's TUI and
    /// clears this back to nil. Nil for non-chat sessions, sessions
    /// where no permission is pending, and Codex SDK chat (the SDK
    /// doesn't surface permission prompts through tmux).
    @Published public private(set) var pendingPermissionPrompt: PendingPermissionPrompt?

    /// A13 (perf — optimistic composer UI): slot for an in-flight user
    /// turn that has been injected optimistically but not yet confirmed
    /// by the daemon. Published so the composer surface can render the
    /// "Sending…" / "Failed to send" chip without waiting for the JSONL
    /// round-trip. Reconciliation: when the real user-text message lands
    /// in `snapshot.messages` with matching body, `reconcilePending()`
    /// clears this slot. Rejection (D24): on a 4xx or transport error
    /// the parent flips this to `.failed` and the bubble stays visible
    /// with a retry chip until the user resends or dismisses.
    @Published public private(set) var pendingMessage: PendingMessage?

    /// A13 — offline queue. When the daemon is briefly unreachable the
    /// composer enqueues the pending body here; on the next successful
    /// send-completion we drain the queue. Capped at 8 entries so a
    /// long offline window doesn't grow unbounded — anything beyond is
    /// surfaced as `.failed` so the user can manually retry.
    @Published public private(set) var queuedPendingMessages: [PendingMessage] = []

    /// A13 hard cap on the offline queue. Beyond this we stop enqueueing
    /// silently — extra sends fail-loud with a chip so the user knows.
    public static let offlineQueueLimit: Int = 8

    public func setPendingPermissionPrompt(_ prompt: PendingPermissionPrompt?) {
        guard pendingPermissionPrompt != prompt else { return }
        pendingPermissionPrompt = prompt
        Task { [staging] in await staging.touch() }
    }
    /// External plan text (from AgentSession.planText). When set, the
    /// next staging snapshot extracts steps from this text and merges
    /// them with steps found in chat messages. The view doesn't have to
    /// observe AgentSession separately — `snapshot.planSteps` is the
    /// single source of truth for the Plan tab.
    public func setPlanText(_ text: String?) {
        Task { [staging] in await staging.setPlanText(text) }
    }

    /// v0.7.8: replace the Codex SDK todo list snapshot. Called from
    /// CodexSDKEventIngestor when the SDK fires a `todo_list` event.
    /// Pass an empty array to clear (the SDK does NOT emit a final
    /// "list closed" event, so clearing on session end is up to the
    /// caller).
    public func setCodexTodos(_ todos: [CodexTodoItem]) {
        Task { [staging] in await staging.setCodexTodos(todos) }
    }

    /// v0.23 (Chat V2): transition the session's per-turn lifecycle.
    /// Called from each provider's ingestor:
    ///   - JSONLTail (Claude) → `.streaming` on first assistant content,
    ///     `.completed` on the JSONL `result` line, `.interrupted` on the
    ///     SessionInterruptDispatcher's tmux ESC dispatch.
    ///   - CodexSDKEventIngestor → `.streaming` on first SDK event of a
    ///     turn, `.completed` on `turn.completed`, `.interrupted` on
    ///     AbortController.abort().
    ///   - AntigravityChatIngestor → `.streaming` on first agentapi chunk,
    ///     `.completed` on `chunk_done` / terminal frame, `.interrupted`
    ///     on the `/cancel` endpoint.
    /// The transition is idempotent: re-setting the same state is a
    /// no-op and does NOT bump the snapshot counter.
    public func setCurrentTurnState(_ state: TurnState) {
        Task { [staging] in await staging.setCurrentTurnState(state) }
    }

    // MARK: - A13 optimistic pending message API

    /// A13 — inject an optimistic pending message slot so the composer
    /// surface can render a "Sending…" bubble within 1 frame of the user
    /// tapping Send. The body is trimmed to match
    /// `ComposerStore.renderPromptBody`'s prose extraction so
    /// reconcile-by-body lines up with the JSONL `user` line that lands
    /// later. Returns the freshly-injected `PendingMessage` so the caller
    /// can mark failure / retry against this specific id.
    @discardableResult
    public func injectPending(text: String, attachmentRefs: [String] = []) -> PendingMessage {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = PendingMessage(
            body: trimmed,
            attachmentRefs: attachmentRefs,
            state: .sending
        )
        pendingMessage = pending
        return pending
    }

    /// A13 — explicit clear. The composer calls this after the JSONL
    /// confirmation lands (`reconcilePending(matching:)` failed to find a
    /// match within the watch window — the daemon ack is the authoritative
    /// signal that the turn is in flight even before the user line shows
    /// up on disk).
    public func clearPending() {
        guard pendingMessage != nil else { return }
        pendingMessage = nil
    }

    /// A13 — flip the pending bubble to `.failed` (D24 rejection
    /// handling). The bubble stays visible with an error chip so the
    /// user can retry or dismiss; it's NOT silently dropped. `error`
    /// is surfaced verbatim in the chip text.
    public func markPendingFailed(error: String) {
        guard let current = pendingMessage else { return }
        pendingMessage = current.failing(error: error)
    }

    /// A13 — flip the pending bubble back into `.sending` state. Used
    /// when the user taps Retry on a previously-failed pending; the
    /// composer issues another network call and re-uses the same slot
    /// instead of injecting a new pending (so the bubble doesn't flicker
    /// out and back in).
    public func markPendingRetrying() {
        guard let current = pendingMessage else { return }
        pendingMessage = current.retrying()
    }

    /// A13 — flip the pending bubble to `.queuedOffline` so the user
    /// sees their message is staged but not yet sent. Used when the
    /// daemon is briefly unreachable; the composer drains the queue
    /// via `dequeueOfflinePending()` on the next successful send.
    public func markPendingQueuedOffline(error: String? = nil) {
        guard let current = pendingMessage else { return }
        let queued = current.queuedOffline(error: error)
        pendingMessage = queued
        if queuedPendingMessages.count < Self.offlineQueueLimit {
            queuedPendingMessages.append(queued)
        } else {
            // Cap exceeded — surface as failed so the user knows the
            // offline buffer is full instead of silently dropping.
            markPendingFailed(error: "Offline queue full — retry manually.")
        }
    }

    /// A13 — drain the offline queue. Returns the queued pendings in
    /// FIFO order so the caller can replay each in sequence. The store
    /// drops them from the published queue immediately; if the replay
    /// fails the caller re-enqueues via `markPendingQueuedOffline`.
    public func dequeueOfflineQueue() -> [PendingMessage] {
        let drained = queuedPendingMessages
        queuedPendingMessages.removeAll()
        return drained
    }

    /// A13 — auto-reconcile. Called whenever the snapshot updates, this
    /// walks the recent user-text messages and clears the pending slot
    /// when a matching body appears (the JSONL `user` line landed). The
    /// match window is narrow: only the most-recent 4 user-text messages
    /// are scanned to keep this O(1) regardless of transcript length.
    /// No-op when there's no pending or when pending is in `.failed`
    /// state (D24: failed pendings stay visible until the user acts).
    public func reconcilePendingIfMatched() {
        guard let pending = pendingMessage, pending.state == .sending else { return }
        let recentUserBodies: [String] = snapshot.messages
            .reversed()
            .lazy
            .filter { $0.kind == .userText }
            .prefix(4)
            .map { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) }
        if recentUserBodies.contains(pending.body) {
            pendingMessage = nil
        }
    }

    /// v0.7.4: ingest Codex SDK stream events into the same staging pipeline
    /// JSONL tail uses, so SDK observation flows into the existing iOS
    /// `chat-subscribe` WS feed without a separate channel.
    /// Caller (CodexSDKEventIngestor) maps SDK events into ChatMessage and
    /// hands them here with whatever token deltas turn.completed reported.
    public func appendSDKMessages(
        _ messages: [ChatMessage],
        at timestamp: Date = Date(),
        deltaInputTokens: Int = 0,
        deltaOutputTokens: Int = 0,
        deltaCacheCreationTokens: Int = 0,
        deltaCacheReadTokens: Int = 0,
        model: String? = nil,
        suppressMirror: Bool = false
    ) {
        let hasTokenDelta = deltaInputTokens != 0
            || deltaOutputTokens != 0
            || deltaCacheCreationTokens != 0
            || deltaCacheReadTokens != 0
        guard !messages.isEmpty || hasTokenDelta || model != nil else { return }
        let line = ParsedLine(
            timestamp: timestamp,
            messages: messages,
            deltaInputTokens: deltaInputTokens,
            deltaOutputTokens: deltaOutputTokens,
            deltaCacheCreationTokens: deltaCacheCreationTokens,
            deltaCacheReadTokens: deltaCacheReadTokens,
            model: model
        )
        Task { [staging] in await staging.ingest(line) }
        // v0.9.x.1 — mirror every appended message to disk so a fresh
        // store post-evict can backfill the chat thread. Only sdkOnly
        // stores need this (CLI/JSONL-backed stores already have a
        // disk transcript). suppressMirror=true is set during replay
        // so we don't re-write the same messages on every replay cycle.
        if sdkOnly && !suppressMirror && !messages.isEmpty {
            SDKChatTranscriptMirror.append(sessionId: sessionId, messages: messages)
        }
    }

    public func loadOlderHistory(limit: Int = 200) async {
        guard !sdkOnly, hasOlderHistory else { return }
        guard let oldestId = snapshot.messages.first?.id else { return }
        let url = sessionFileURL
        let currentCount = snapshot.messages.count
        let page = await Task.detached(priority: .utility) {
            TranscriptLoader.loadWindowBefore(from: url, beforeId: oldestId, limit: limit)
        }.value
        guard page.cursorFound else {
            hasOlderHistory = false
            return
        }
        guard !page.messages.isEmpty else {
            hasOlderHistory = false
            return
        }
        let window = page.messages
        await staging.expandRetainedMessageLimit(to: currentCount + window.count)
        await staging.ingestBatch(window.map { message in
            ParsedLine(
                timestamp: message.at,
                messages: [message],
                deltaInputTokens: 0,
                deltaOutputTokens: 0,
                deltaCacheCreationTokens: 0,
                deltaCacheReadTokens: 0,
                model: nil
            )
        })
        hasOlderHistory = page.truncated
    }

    public let sessionId: UUID
    /// v0.8 QA: was `private let` — now `private var` so chat-mode Codex CLI
    /// sessions can swap the tailed file when the CLI rotates its rollout
    /// per turn. `switchTailedFile(to:)` re-aims the JSONLTail at the new
    /// URL while keeping the SAME store identity, so the Mac UI's
    /// @ObservedObject chain stays intact and snapshot updates flow.
    private var sessionFileURL: URL
    private var tail: JSONLTail?
    /// Background parser actor — owns ChatItemBuilder, ingests typed
    /// `ParsedLine` values, never touches main. Replaced on every fresh
    /// start so stale in-flight work from an older file/generation cannot
    /// reset or republish the current transcript.
    private var staging = StagingParser()
    /// Generation token (codex tension #6). Bumped on every `start()` /
    /// `stop()`. Background commit task captures its generation at launch
    /// and silently drops any commit where the captured generation
    /// doesn't match the current — so stale parses from an evicted
    /// store can't publish after navigation.
    private var parseGeneration: UInt64 = 0
    private var commitTask: Task<Void, Never>?
    /// Reverse-tail ingest task — tracked so `stop()` cancels it (was
    /// previously fire-and-forget, so a `stop()` followed by `start()`
    /// could let the old reverse-tail's late ingests bleed into the new
    /// parse generation through the shared StagingParser).
    private var ingestTailTask: Task<Void, Never>?
    /// Per-line ingest tasks spawned by the JSONLTail handler. These are
    /// also tracked so `stop()` cancels them; combined with the per-task
    /// generation check inside the ingest closure, this closes the
    /// "stop() doesn't stop all writers" race surfaced in /review.
    private var perLineIngestTasks: [Task<Void, Never>] = []

    /// v0.8 NEW-E3: when true, `start()` skips JSONLTail + reverse-tail
    /// entirely. Only the commit task runs, which picks up
    /// `appendSDKMessages()` writes from CodexSDKEventIngestor. Used by
    /// Codex SDK chat sessions which have no JSONL file on disk —
    /// transcript lives server-side, the SDK streams events.
    private let sdkOnly: Bool

    /// v0.8 QA: expose the current JSONL file the store is tailing so
    /// DaemonChatStoreRegistry can detect rollout rotation in chat-mode
    /// Codex CLI sessions (Codex CLI writes a fresh rollout per turn).
    public var currentFileURL: URL { sessionFileURL }

    /// v0.8 QA F1: lets the registry detect an sdkOnly fallback store
    /// and rebuild it as a JSONL-backed store once a matching rollout
    /// finally appears on disk (Codex CLI chat created before the
    /// user's first prompt = no rollout yet at createStore time).
    public var isSDKOnly: Bool { sdkOnly }

    /// v0.8 QA: re-aim the JSONLTail at a new file in place. Used when
    /// Codex CLI rotates its rollout per turn — without this, the daemon
    /// would have to create a NEW SessionChatStore which would
    /// invalidate the Mac UI's @ObservedObject reference and freeze the
    /// transcript on the previous turn. By keeping the same store
    /// identity and just swapping the underlying file, the @Published
    /// `snapshot` keeps streaming updates and the view re-renders.
    /// Safe to call when the store is already tailing a different file;
    /// no-op when called with the URL we're already tailing.
    public func switchTailedFile(to newURL: URL) {
        guard !sdkOnly else { return }
        guard newURL != sessionFileURL else { return }
        chatLogger.info("Switching tailed file for session \(self.sessionId.uuidString, privacy: .public): \(self.sessionFileURL.lastPathComponent, privacy: .public) → \(newURL.lastPathComponent, privacy: .public)")
        // Stop the current tail + cancel in-flight ingest tasks, then
        // re-aim and re-start. start() swaps in a fresh staging actor, so the new
        // snapshot starts empty and gets repopulated from the new file.
        // For Codex CLI this is correct because each rotated rollout
        // contains the full conversation history (the CLI passes the
        // previous threadId on resume), so no entries are lost in the
        // user-visible chat thread. If we ever wire this for an agent
        // that doesn't carry forward history per file (e.g. a future
        // Claude rotation path), revisit whether to preserve staging.
        tail?.stop()
        tail = nil
        ingestTailTask?.cancel()
        ingestTailTask = nil
        for task in perLineIngestTasks { task.cancel() }
        perLineIngestTasks.removeAll()
        // Update URL and re-start the tail. parseGeneration bumps inside
        // start(), so any stale per-line ingests that survive the cancel
        // get dropped by the generation check.
        sessionFileURL = newURL
        commitTask?.cancel()
        commitTask = nil
        start()
    }

    public init(sessionId: UUID, sessionFileURL: URL) {
        self.sessionId = sessionId
        self.sessionFileURL = sessionFileURL
        self.sdkOnly = false
    }

    /// v0.8 Phase 4.5: SDK-only init for Codex SDK chat sessions. No
    /// JSONL file is tailed; events arrive via `appendSDKMessages` from
    /// the CodexSDKEventIngestor. The sessionFileURL stays as a sentinel
    /// (`/dev/null`) so the field is non-nil but unused.
    public init(sessionId: UUID, sdkOnly: Bool) {
        precondition(sdkOnly, "Use init(sessionId:sessionFileURL:) for JSONL-backed stores")
        self.sessionId = sessionId
        self.sessionFileURL = URL(fileURLWithPath: "/dev/null")
        self.sdkOnly = true
    }

    public func start() {
        // sdkOnly stores have no `tail`, so the original `tail == nil`
        // guard would let start() be called repeatedly. Use the commit
        // task as the canonical "already started" signal — it's set in
        // both modes.
        guard commitTask == nil else { return }
        parseGeneration &+= 1
        let generation = parseGeneration
        let signpostID = OSSignpostID(log: chatPerfLog, object: self)
        os_signpost(.begin, log: chatPerfLog, name: "session-open",
                    signpostID: signpostID,
                    "session=%{public}@", self.sessionId.uuidString)
        startSignpostID = signpostID
        chatLogger.info("Starting chat store for session \(self.sessionId.uuidString, privacy: .public) at \(self.sessionFileURL.path, privacy: .public)")
        snapshot = .empty
        isLoading = true
        hasOlderHistory = false

        // A fresh actor is cheaper and safer than an async reset. It makes
        // session open deterministic: no stale actor task can clear the
        // recent 200-message seed after it has been ingested.
        self.staging = StagingParser()
        let staging = self.staging

        // v0.8 Phase 4.5: SDK-only stores skip JSONLTail + reverse-tail
        // because no JSONL file exists. The commit task below still runs
        // and picks up `appendSDKMessages` writes from
        // CodexSDKEventIngestor through the staging actor.
        if !sdkOnly {
            // Seed the transcript from the recent tail first. The live
            // JSONLTail below starts from this byte offset, so opening a
            // long session never paints the first historical JSONL row before
            // the current turn and still doesn't miss appends during startup.
            // The staging actor keeps only the latest chatRecentMessageLimit
            // messages, which is the scrollback budget for the workbench UI.
            let sessionURL = self.sessionFileURL
            let liveTailStartOffset = Self.fileSize(at: sessionURL)
            ingestTailTask = Task.detached(priority: .userInitiated) { [weak self] in
                await Self.ingestTail(
                    url: sessionURL,
                    into: staging,
                    generation: generation,
                    store: self,
                    maxMessages: chatRecentMessageLimit,
                    maxBytes: chatInitialTailByteBudget
                )
            }

            // JSONLTail runs on its background queue. The handler converts
            // [String: Any] → typed `ParsedLine` (Sendable) BEFORE crossing
            // into the actor — codex tension #7b: typed boundary, not raw
            // dictionaries. The per-line task is tracked on `self` so
            // `stop()` can cancel it; the closure-level generation check
            // also drops late ingests from a prior parse generation.
            let tail = JSONLTail(fileURL: sessionFileURL, initialReadMode: .fromOffset(liveTailStartOffset)) { [weak self] json in
                // v0.23 T4: per-turn lifecycle dispatch BEFORE the
                // typed parse. Claude's JSONL line shape carries the
                // turn-state hint in the top-level "type" field:
                //   - "assistant"  → first content of a new turn (or
                //                    continuation); transition into
                //                    `.streaming`. Idempotent on the
                //                    store side so re-firing on every
                //                    assistant line is cheap.
                //   - "result"     → Claude's end-of-turn marker.
                //                    Transition into `.completed` —
                //                    the V2 status strip clamps the
                //                    stopwatch + flips Stop→Send.
                //   - "user"       → starts a fresh turn; reset to
                //                    `.streaming` because the
                //                    assistant's response is about to
                //                    begin. (`.idle` would briefly
                //                    flicker the UI off; leave it as
                //                    `.streaming` so the indicator
                //                    stays on through the round trip.)
                if let type = json["type"] as? String {
                    // Interactive Claude CLI's natural end-of-turn marker
                    // is `type: "assistant"` with `message.stop_reason ==
                    // "end_turn"` (or other terminal reasons). The
                    // headless `claude -p` mode uses `type: "result"`.
                    // `stop_reason: "tool_use"` is NOT terminal — the
                    // assistant pauses mid-turn for a tool call and
                    // continues after the tool result.
                    let stopReason = (json["message"] as? [String: Any])?["stop_reason"] as? String
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.parseGeneration == generation else { return }
                        switch type {
                        case "result":
                            self.setCurrentTurnState(.completed)
                        case "assistant":
                            switch stopReason {
                            case "end_turn", "stop_sequence", "max_tokens", "refusal":
                                self.setCurrentTurnState(.completed)
                            default:
                                self.setCurrentTurnState(.streaming)
                            }
                        case "user":
                            self.setCurrentTurnState(.streaming)
                        default:
                            break
                        }
                    }
                }
                guard let parsed = ParsedLine.from(json: json) else { return }
                let task = Task { [weak self] in
                    guard let self else { return }
                    let currentGen = await MainActor.run { self.parseGeneration }
                    guard currentGen == generation else { return }
                    await staging.ingest(parsed)
                }
                Task { @MainActor [weak self] in
                    self?.perLineIngestTasks.append(task)
                }
            }
            self.tail = tail
            tail.start()
        }

        // Background commit task: every 16ms, snapshot the staging actor
        // and publish to main. Generation-token guard suppresses any
        // commits from stale parses (codex tension #6). T14 signposts
        // make each batch visible in Instruments → Animation Hitches.
        commitTask = Task.detached(priority: .userInitiated) { [weak self] in
            var lastCommittedCounter: UInt64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                let next = await staging.snapshot()
                guard next.updateCounter != lastCommittedCounter else { continue }
                let signpostID = OSSignpostID(log: chatPerfLog)
                os_signpost(.begin, log: chatPerfLog, name: "staging-parse-batch",
                            signpostID: signpostID,
                            "items=%d counter=%llu",
                            next.items.count, next.updateCounter)
                lastCommittedCounter = next.updateCounter
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    guard self.parseGeneration == generation else { return }
                    self.snapshot = next
                    // No `messages` rebuild here — it's a computed
                    // property derived from `snapshot.items` on demand,
                    // so we get a single objectWillChange per commit
                    // rather than two parallel @Published mutations.
                    // A13: now that a new snapshot has landed, see whether
                    // the freshly-ingested JSONL lines include the optimistic
                    // pending message body. If so, clear the pending slot so
                    // the composer's "Sending…" bubble dissolves into the
                    // real bubble without a flicker.
                    self.reconcilePendingIfMatched()
                }
                os_signpost(.end, log: chatPerfLog, name: "staging-parse-batch",
                            signpostID: signpostID)
            }
        }

        // Mark loading false after a settle window.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.parseGeneration == generation else { return }
            self.isLoading = false
            if let id = self.startSignpostID {
                os_signpost(.end, log: chatPerfLog, name: "session-open",
                            signpostID: id,
                            "messageCount=%d", self.snapshot.items.count)
                self.startSignpostID = nil
            }
        }
    }

    private var startSignpostID: OSSignpostID?

    public func stop() {
        // Bump generation so any in-flight commit task drops its next
        // publish (defense-in-depth with Task cancellation).
        parseGeneration &+= 1
        commitTask?.cancel()
        commitTask = nil
        ingestTailTask?.cancel()
        ingestTailTask = nil
        // Cancel any per-line ingest tasks that haven't finished yet.
        // The generation guard inside each task is the primary defense;
        // explicit cancel just shortens the time window during which a
        // stopped store's queued ingests can still hit the actor.
        for task in perLineIngestTasks { task.cancel() }
        perLineIngestTasks.removeAll(keepingCapacity: false)
        tail?.stop()
        tail = nil
        // Close out the session-open signpost if start()'s 500ms isLoading
        // task didn't reach it before stop(). Without this, Instruments
        // traces show an unbounded `session-open` interval that never
        // ends — confusing during perf analysis.
        if let id = startSignpostID {
            os_signpost(.end, log: chatPerfLog, name: "session-open",
                        signpostID: id,
                        "messageCount=%d stopped=1", self.snapshot.items.count)
            startSignpostID = nil
        }
    }

    /// Safety net for the rare case where a caller drops the store
    /// without calling `stop()` first. `commitTask` is detached and
    /// keeps spinning the 16ms poll until cancelled; cancelling here
    /// ensures the only way for the task to outlive the store is the
    /// `[weak self]` guard at the MainActor hop (which still exits
    /// cleanly, just one frame later than necessary).
    deinit {
        commitTask?.cancel()
        tail?.stop()
    }

    private nonisolated static func fileSize(at url: URL) -> UInt64 {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber
        else {
            return 0
        }
        return size.uint64Value
    }

    /// Read the recent tail of the JSONL, parse complete lines, and
    /// batch-ingest the newest messages into the staging actor. The first
    /// line in the chunk is
    /// likely partial (we seeked mid-line) so we skip to the first newline
    /// before parsing. Fail-quiet on any error; live appends are covered by
    /// JSONLTail starting at EOF.
    ///
    /// The `generation` argument is captured at `start()` time and
    /// checked before each ingest so a `stop()` that races the
    /// reverse-tail can prevent stale ingests from polluting a future
    /// parse. `Task.checkCancellation()` is the primary defense; the
    /// generation check is the belt to the cancellation suspenders.
    private nonisolated static func ingestTail(
        url: URL,
        into staging: StagingParser,
        generation: UInt64,
        store: SessionChatStore?,
        maxMessages: Int,
        maxBytes: UInt64
    ) async {
        let signpostID = OSSignpostID(log: chatPerfLog)
        os_signpost(.begin, log: chatPerfLog, name: "tail-read",
                    signpostID: signpostID,
                    "path=%{public}@", url.lastPathComponent)
        defer {
            os_signpost(.end, log: chatPerfLog, name: "tail-read",
                        signpostID: signpostID)
        }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        guard let size = (try? fh.seekToEnd()) else { return }
        let chunkSize = max(UInt64(64 * 1024), maxBytes)
        let start: UInt64 = size > chunkSize ? size - chunkSize : 0
        do { try fh.seek(toOffset: start) } catch { return }
        guard let bytes = try? fh.readToEnd(), !bytes.isEmpty else { return }

        // If we started mid-file, skip to first newline (drop the partial
        // leading line). When start==0 we begin at byte 0 — keep everything.
        var slice = bytes[bytes.startIndex...]
        if start > 0, let nl = slice.firstIndex(of: 0x0A) {
            slice = bytes[bytes.index(after: nl)...]
        }
        // Parse complete lines first, then batch-ingest only the suffix
        // needed for the initial viewport. This prevents the first publish
        // from showing old history during long-file startup.
        var parsedLines: [ParsedLine] = []
        var parsedMessageCount = 0
        var lineStart = slice.startIndex
        while lineStart < slice.endIndex {
            if Task.isCancelled { return }
            let newlineIdx = slice[lineStart...].firstIndex(of: 0x0A) ?? slice.endIndex
            let lineBytes = slice[lineStart..<newlineIdx]
            lineStart = (newlineIdx < slice.endIndex)
                ? slice.index(after: newlineIdx)
                : slice.endIndex
            guard !lineBytes.isEmpty else { continue }
            guard let json = (try? JSONSerialization.jsonObject(with: lineBytes)) as? [String: Any] else { continue }
            guard let parsed = ParsedLine.from(json: json) else { continue }
            parsedLines.append(parsed)
            parsedMessageCount += parsed.messages.count
        }
        guard !parsedLines.isEmpty else { return }
        if let store {
            let currentGen = await MainActor.run { store.parseGeneration }
            guard currentGen == generation else { return }
            let hasOlder = start > 0 || parsedMessageCount > maxMessages
            await MainActor.run {
                guard store.parseGeneration == generation else { return }
                store.hasOlderHistory = hasOlder
            }
        }
        var suffix: [ParsedLine] = []
        suffix.reserveCapacity(min(parsedLines.count, maxMessages))
        var remaining = maxMessages
        for parsed in parsedLines.reversed() {
            guard remaining > 0 else { break }
            suffix.append(parsed)
            remaining -= max(parsed.messages.count, 1)
        }
        await staging.ingestBatch(suffix.reversed())
    }

    /// Flatten `ChatItem.toolRun` pairs back into a flat message array.
    /// Order matches arrival order — useful for back-compat views and
    /// for `PRMirror.findPRURL` which scans every assistant body / tool
    /// result for a github.com PR URL.
    private static func flattenMessages(from items: [ChatItem]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for item in items {
            switch item {
            case .message(let m):
                out.append(m)
            case .toolRun(_, let pairs):
                for pair in pairs {
                    out.append(pair.call)
                    if let r = pair.result { out.append(r) }
                }
            }
        }
        return out
    }

    // MARK: - Helpers (used by ParsedLine.from)
    // The legacy main-actor `applyLine` / `handleUser` / `handleAssistant`
    // path was replaced by the off-main `ParsedLine.from(json:)` →
    // `StagingParser.ingest(_:)` pipeline. Helpers below are marked
    // `nonisolated` so ParsedLine.from can call them from any context.

    /// Generate a stable id from a JSON line's uuid/timestamp field.
    nonisolated static func stableId(_ json: [String: Any], suffix: String) -> String {
        let uuid = (json["uuid"] as? String) ?? (json["timestamp"] as? String) ?? UUID().uuidString
        return "\(uuid):\(suffix)"
    }

    /// Compact one-line summary of a tool_use `input` for the row label. This
    /// is what the user sees in the collapsed disclosure header — favors a
    /// human-readable description over the raw command bytes.
    nonisolated static func summarizeInput(_ input: Any?, for tool: String) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        switch tool {
        case "Bash":
            // Claude Code passes a one-liner `description` alongside the
            // command; use that as the headline so "Ran Stop the old build"
            // reads better than "Ran kill 3487 2>&1 …".
            if let desc = (dict["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !desc.isEmpty {
                return desc
            }
            if let cmd = dict["command"] as? String {
                return cmd.replacingOccurrences(of: "\n", with: " ")
            }
        case "Read":
            if let path = dict["file_path"] as? String { return path }
        case "Write", "Edit":
            if let path = dict["file_path"] as? String { return path }
        case "Glob", "Grep":
            if let pattern = dict["pattern"] as? String { return pattern }
        case "WebFetch":
            if let url = dict["url"] as? String { return url }
        case "WebSearch":
            if let q = dict["query"] as? String { return q }
        // v0.23 T12: Codex SDK + Antigravity emit `web_search` /
        // `web_fetch` instead of CamelCase. Same field shape.
        case "web_search":
            if let q = dict["query"] as? String { return q }
            if let q = dict["q"] as? String { return q }
        case "web_fetch":
            if let url = dict["url"] as? String { return url }
        case "Task":
            if let desc = dict["description"] as? String { return desc }
        default:
            break
        }
        // Fallback: shortest non-empty string field.
        let stringFields = dict.compactMap { (_, v) -> String? in
            if let s = v as? String, !s.isEmpty { return s }
            return nil
        }
        return stringFields.min(by: { $0.count < $1.count }) ?? ""
    }

    /// Codex tool-input summarizer. Thin wrapper over the Shared
    /// `CodexJSONLParser.summarizeInput` so iOS + tests can use the same
    /// logic. The Mac-side decoder calls this through the parser
    /// directly; this wrapper exists so the Claude-side helpers can keep
    /// addressing Codex names without importing CodexJSONLParser at
    /// every callsite.
    nonisolated static func summarizeCodexInput(
        _ dict: [String: Any], for tool: String, fallback: String
    ) -> String {
        CodexJSONLParser.summarizeInput(dict, for: tool, fallback: fallback)
    }

    /// Verbose detail shown only when the user expands the tool row. For
    /// Bash this is the full command (multi-line preserved); for file ops
    /// `nil` — the path in the headline is already the full detail.
    nonisolated static func expandedDetail(_ input: Any?, for tool: String) -> String? {
        guard let dict = input as? [String: Any] else { return nil }
        switch tool {
        case "Bash":
            return dict["command"] as? String
        case "Grep":
            // Pattern is the headline; surface the optional path/include
            // glob in the detail so the row can show full scope on expand.
            var bits: [String] = []
            if let path = dict["path"] as? String, !path.isEmpty { bits.append("path: \(path)") }
            if let include = dict["include"] as? String, !include.isEmpty { bits.append("include: \(include)") }
            return bits.isEmpty ? nil : bits.joined(separator: "\n")
        case "Task":
            return dict["prompt"] as? String
        case "WebFetch":
            return dict["prompt"] as? String
        case "exec_command", "shell", "spawn_agent", "apply_patch":
            // Codex tool detail — Shared parser owns the schema, so
            // adding a new Codex tool only requires updating one site.
            return CodexJSONLParser.expandedDetail(dict, for: tool)
        default:
            return nil
        }
    }

    /// tool_result `content` may be a string OR array of blocks. Flatten to
    /// a single string, joining text blocks with newlines.
    nonisolated static func flattenContent(_ content: Any?, limit: Int? = nil) -> String {
        if let s = content as? String {
            guard let limit else { return s }
            return String(s.prefix(limit))
        }
        if let blocks = content as? [[String: Any]] {
            let strs = blocks.compactMap { block -> String? in
                if block["type"] as? String == "text" {
                    return block["text"] as? String
                }
                return nil
            }
            let joined = strs.joined(separator: "\n")
            guard let limit else { return joined }
            return String(joined.prefix(limit))
        }
        return ""
    }

    nonisolated static func parseTimestamp(_ json: [String: Any]) -> Date? {
        if let s = json["timestamp"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
            let g = ISO8601DateFormatter()
            return g.date(from: s)
        }
        return nil
    }

    /// Resolve the JSONL file for a session. Claude encodes the cwd as
    /// `~/.claude/projects/<encoded>/<session-id>.jsonl`, replacing `/`,
    /// `_`, AND ` ` (and arguably more) with `-`. The naive `/`→`-` we used
    /// pre-G2 silently missed any cwd containing underscores or spaces —
    /// the very case in this repo (`/Users/darshanbathija_1/Downloads/CC Watch/...`).
    ///
    /// We also walk up parent directories: when Claude was launched from a
    /// parent of the git repo (e.g. `CC Watch/` instead of `CC Watch/Clawdmeter/`),
    /// the JSONLs are filed under the parent's encoded name. `RepoIdentity.normalize`
    /// has already descended us into the git child, but the project dir is
    /// for the parent. Walking up catches it.
    public nonisolated static func resolveSessionFileURL(repoCwd: String) -> URL? {
        let home = ClawdmeterRealHome.url()
        let projects = home.appendingPathComponent(".claude/projects")
        var current = (repoCwd as NSString).standardizingPath
        while !current.isEmpty, current != "/" {
            if let url = newestJSONL(in: projects, claudeEncoded: encodeCwd(current)) {
                return url
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    /// Claude's project-dir name encoding. `/`, `_`, and ` ` all collapse
    /// to `-`. Letter case is preserved.
    nonisolated static func encodeCwd(_ cwd: String) -> String {
        cwd
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    private nonisolated static func newestJSONL(in projects: URL, claudeEncoded: String) -> URL? {
        let dir = projects.appendingPathComponent(claudeEncoded)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        let jsonls = contents.filter { $0.pathExtension == "jsonl" }
        return jsonls.max { a, b in
            let ad = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return ad < bd
        }
    }
}

// MARK: - ParsedLine (typed Sendable boundary)

/// Typed representation of one JSONL line. Converted from `[String: Any]`
/// on the JSONLTail's dispatch queue (off main + off actor), then crossed
/// into the StagingParser actor as a `Sendable` value. Closes the codex
/// tension #7b trap: `[String: Any]` is not properly Sendable.
struct ParsedLine: Sendable {
    let timestamp: Date
    let messages: [ChatMessage]
    /// Per-category token deltas pulled from `message.usage` on Claude
    /// assistant turns. Each category is billed at a different rate —
    /// cache_read at 10% of fresh input, cache_creation at 125% — so
    /// keeping them separate is required for an accurate cost estimate.
    /// All zero for user/meta lines and for Codex (Codex's token totals
    /// live in `event_msg.token_count` events the chat parser doesn't
    /// surface).
    let deltaInputTokens: Int
    let deltaOutputTokens: Int
    let deltaCacheCreationTokens: Int
    let deltaCacheReadTokens: Int
    /// Model the message was billed against (`message.model`). Used as
    /// the cost-estimator hint — we pick the latest seen, since users
    /// sometimes switch mid-session.
    let model: String?

    /// Convert a raw JSONL dict into a typed ParsedLine. Returns `nil` for
    /// lines we don't surface (queue-operation, last-prompt, attachment,
    /// etc.) or malformed lines. Pure value transform.
    ///
    /// Both Claude and Codex JSONLs flow through here:
    /// - Claude lines have `type: "user" | "assistant"` at the top level
    ///   and a `message: {content, usage}` body. We decode them via
    ///   `decodeUser` / `decodeAssistant`.
    /// - Codex lines have `type: "response_item"` with a `payload` carrying
    ///   `type: "message" | "function_call" | "function_call_output" |
    ///   "reasoning"` and a role (`user | assistant | developer`). The
    ///   shape is wildly different from Claude's; `decodeCodexResponseItem`
    ///   handles it.
    static func from(json: [String: Any]) -> ParsedLine? {
        let at = SessionChatStore.parseTimestamp(json) ?? Date()
        let type = json["type"] as? String ?? ""

        // Gemini disambiguator. Both Claude and Gemini use `type: "user"`
        // but the payload shapes differ:
        //   - Claude wraps content under `message: {content: ...}`.
        //   - Gemini puts `content: [{text: ...}]` at top level (no
        //     `message` wrapper) and pairs with a `sessionId`-bearing
        //     header line.
        // If the line has no `message` field, it's Gemini's flat shape;
        // route to the Gemini parser. Also catches `type: "model"` which
        // Gemini emits for assistant turns (vs Claude's `"assistant"`).
        if (type == "user" && json["message"] == nil)
            || type == "model"
            || type == "gemini" {
            return decodeGeminiLine(json: json, at: at)
        }

        switch type {
        case "user":
            return decodeUser(json: json, at: at)
        case "assistant":
            return decodeAssistant(json: json, at: at)
        case "response_item":
            return decodeCodexResponseItem(json: json, at: at)
        default:
            return nil
        }
    }

    /// Gemini JSONL chat decoder — DEPRECATED in v0.6.0.
    ///
    /// Per locked plan decision D1 ("v2-only — drop the Gemini CLI v0.42
    /// path entirely"), Antigravity 2 stopped writing the per-session
    /// JSONL files (`~/.gemini/tmp/<repo>/chats/session-*.jsonl`) that
    /// GeminiJSONLParser consumed. Antigravity 2 writes encrypted
    /// `conversations/<uuid>.pb` files instead — see Commit 4's
    /// `ConversationProtoParser` for the encryption finding.
    ///
    /// In Disk mode (default), the Sessions IDE chat pane for Gemini
    /// sessions stays empty — the Plan pane (Commit 8) is the primary
    /// surface for Antigravity 2 sessions. In SDK mode (Commit 10), the
    /// Python sidecar's observer.py decodes conversation messages via
    /// the SDK's introspection API.
    ///
    /// We keep the discriminator (`type: "gemini"`, `type: "model"`,
    /// `type: "user"` without `message`) so any STILL-EXISTING legacy
    /// v0.42 JSONL on the user's disk parses to "empty chat" rather
    /// than throwing.
    private static func decodeGeminiLine(json: [String: Any], at: Date) -> ParsedLine? {
        // v0.42 JSONL files (~/.gemini/tmp/...) may still exist on disk
        // for users mid-migration. We don't parse them — Antigravity 2
        // is v2-only per D1. Return nil so the line is silently dropped.
        _ = json
        _ = at
        return nil
    }

    /// Codex JSONL chat decoder. Thin wrapper over
    /// `CodexJSONLParser.decodeResponseItem` — the pure transform lives
    /// in Shared (testable + iOS-readable). This wrapper threads the
    /// per-line `stableId` cursor through and wraps the resulting
    /// `[ChatMessage]` in a `ParsedLine` for the Mac staging pipeline.
    private static func decodeCodexResponseItem(json: [String: Any], at: Date) -> ParsedLine? {
        let messages = CodexJSONLParser.decodeResponseItem(json: json, at: at) { suffix in
            SessionChatStore.stableId(json, suffix: suffix)
        }
        guard !messages.isEmpty else { return nil }
        return ParsedLine(
            timestamp: at, messages: messages,
            deltaInputTokens: 0, deltaOutputTokens: 0,
            deltaCacheCreationTokens: 0, deltaCacheReadTokens: 0,
            model: nil
        )
    }

    private static func decodeUser(json: [String: Any], at: Date) -> ParsedLine? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        var out: [ChatMessage] = []
        if let s = message["content"] as? String, !s.isEmpty {
            out.append(ChatMessage(
                id: SessionChatStore.stableId(json, suffix: "user-text"),
                kind: .userText, title: "You", body: s, at: at
            ))
        } else if let blocks = message["content"] as? [[String: Any]] {
            for (i, block) in blocks.enumerated() {
                let blockType = block["type"] as? String ?? ""
                let baseId = SessionChatStore.stableId(json, suffix: "u\(i)-\(blockType)")
                switch blockType {
                case "text":
                    if let s = block["text"] as? String, !s.isEmpty {
                        out.append(ChatMessage(
                            id: baseId, kind: .userText, title: "You",
                            body: s, at: at
                        ))
                    }
                case "tool_result":
                    let resultId = (block["tool_use_id"] as? String) ?? baseId
                    let isError = (block["is_error"] as? Bool) ?? false
                    let fullBody = SessionChatStore.flattenContent(block["content"])
                    let body = SessionChatStore.flattenContent(block["content"], limit: 4096)
                    out.append(ChatMessage(
                        id: "result:\(resultId)", kind: .toolResult,
                        title: "Tool result", body: body,
                        detail: fullBody.count > body.count ? fullBody : nil,
                        at: at,
                        isError: isError
                    ))
                default:
                    break
                }
            }
        }
        guard !out.isEmpty else { return nil }
        return ParsedLine(
            timestamp: at, messages: out,
            deltaInputTokens: 0, deltaOutputTokens: 0,
            deltaCacheCreationTokens: 0, deltaCacheReadTokens: 0,
            model: nil
        )
    }

    private static func decodeAssistant(json: [String: Any], at: Date) -> ParsedLine? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        var out: [ChatMessage] = []
        if let s = message["content"] as? String, !s.isEmpty {
            out.append(ChatMessage(
                id: SessionChatStore.stableId(json, suffix: "a-text"),
                kind: .assistantText, title: "Claude", body: s, at: at
            ))
        } else if let blocks = message["content"] as? [[String: Any]] {
            for (i, block) in blocks.enumerated() {
                let blockType = block["type"] as? String ?? ""
                let baseId = SessionChatStore.stableId(json, suffix: "a\(i)-\(blockType)")
                switch blockType {
                case "text":
                    if let s = block["text"] as? String, !s.isEmpty {
                        out.append(ChatMessage(
                            id: baseId, kind: .assistantText, title: "Claude",
                            body: s, at: at
                        ))
                    }
                case "tool_use":
                    let toolUseId = (block["id"] as? String) ?? baseId
                    let name = (block["name"] as? String) ?? "tool"
                    let inputSummary = SessionChatStore.summarizeInput(
                        block["input"], for: name
                    )
                    let inputDetail = SessionChatStore.expandedDetail(
                        block["input"], for: name
                    )
                    // v0.5.5: Edit / MultiEdit / Write get a structured
                    // EditStats so the chat view can render the
                    // "Edited <file> +N -M" chip instead of folding
                    // into the generic "Ran N commands" card.
                    let editStats = EditStats.fromClaudeInput(block["input"], toolName: name)
                    let editDiff = EditDiff.fromClaudeInput(block["input"], toolName: name)
                    let bashResult: BashResult? = {
                        guard let dict = block["input"] as? [String: Any] else { return nil }
                        return BashResult.fromToolCallInput(dict, toolName: name)
                    }()
                    // v0.5.6: AskUserQuestion lands as an interactive
                    // tappable tray instead of "Ran 1 command". Parsed
                    // here from the raw input dict so the view doesn't
                    // need to re-walk JSON downstream.
                    let askUserQuestion: AskUserQuestion? = (name == "AskUserQuestion")
                        ? AskUserQuestion.fromToolInput(block["input"])
                        : nil
                    out.append(ChatMessage(
                        id: "call:\(toolUseId)", kind: .toolCall, title: name,
                        body: inputSummary, detail: inputDetail, at: at,
                        editStats: editStats,
                        askUserQuestion: askUserQuestion,
                        editDiff: editDiff,
                        bashResult: bashResult
                    ))
                default:
                    break
                }
            }
        }
        guard !out.isEmpty else { return nil }
        // Split Claude's `message.usage` into the four categories
        // ClaudeUsageParser uses for analytics. Conflating them into a
        // single `inputTokens` value undercounted cost by ~80x in the
        // activity strip because cache_read is billed at 10% of fresh
        // input AND because Pricing.cost previously silently dropped
        // input tokens past the 200K boundary for un-tiered models.
        var inTok = 0
        var outTok = 0
        var cacheCreate = 0
        var cacheRead = 0
        if let usage = message["usage"] as? [String: Any] {
            inTok = (usage["input_tokens"] as? Int) ?? 0
            outTok = (usage["output_tokens"] as? Int) ?? 0
            cacheCreate = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        }
        let model = (message["model"] as? String)
        return ParsedLine(
            timestamp: at, messages: out,
            deltaInputTokens: inTok, deltaOutputTokens: outTok,
            deltaCacheCreationTokens: cacheCreate, deltaCacheReadTokens: cacheRead,
            model: model
        )
    }
}

// MARK: - StagingParser (background actor)

/// Owns the `ChatItemBuilder` + dedup state. Consumes typed `ParsedLine`
/// values from off-main contexts (JSONLTail's dispatch queue → ParsedLine
/// conversion → Task into this actor). Exposes the latest snapshot for
/// the @MainActor commit task to poll.
///
/// Why an actor (vs the previous @MainActor in-line work):
/// - All parsing work moves off the main thread (codex tension #1).
/// - Per-line scheduling overhead drops from "Task hop per line" to
///   "one snapshot poll per 16ms frame".
/// - ChatItemBuilder + dedup state are isolated by the actor — no
///   manual locking, no @MainActor pinning.
actor StagingParser {
    /// Messages kept in chronological order (by `at` timestamp, with a
    /// kind-based tiebreak — see `insertIndex(for:)`). Startup seeds this
    /// from the recent tail in one batch; JSONLTail then follows only new
    /// appends. The retained window is capped so the UI never renders the
    /// entire historical transcript.
    private var sortedMessages: [ChatMessage] = []
    private var seenIds: Set<String> = []
    /// External plan text (AgentSession.planText) injected via
    /// `SessionChatStore.setPlanText`. Drives the `planSteps` precompute
    /// alongside steps mined from assistant messages.
    private var planText: String? = nil
    /// v0.7.8: latest Codex SDK `todo_list` event payload. Set by
    /// `setCodexTodos(_:)`, surfaced in ChatSnapshot for the CodexPlanPane
    /// (Mac), iOSCodexPlanView (iOS), and CodexTaskComplication (Watch).
    private var codexTodos: [CodexTodoItem] = []
    /// v0.23 (Chat V2): explicit per-turn lifecycle. Each provider's
    /// ingestor (JSONLTail for Claude, CodexSDKEventIngestor for Codex
    /// SDK, AntigravityChatIngestor for Gemini) transitions this
    /// via `setCurrentTurnState(_:)` on natural turn boundaries:
    ///   - `.streaming` on first content of a new turn
    ///   - `.completed` on the provider's terminal event
    ///   - `.interrupted` on cancel
    ///   - `.idle` on next user prompt
    /// Surfaced in `ChatSnapshot.currentTurnState` so the V2 status
    /// strip can drive the stopwatch + Stop↔Send transitions
    /// deterministically.
    private var currentTurnState: TurnState = .idle
    /// Accumulated tokens for the session metadata strip — split into
    /// the four billable categories so the cost estimator can apply
    /// the right rate per category. Pulled from `message.usage` on
    /// Claude assistant turns; all zero for Codex (handled in analytics).
    private var totalInputTokens: Int = 0
    private var totalOutputTokens: Int = 0
    private var totalCacheCreationTokens: Int = 0
    private var totalCacheReadTokens: Int = 0
    /// Most-recently ingested turn's tokens — overwritten (not summed) on
    /// each ingest with non-zero usage. Drives the composer's context-
    /// window meter; the cumulative totals overstate working memory size
    /// by the turn count because cache reads are re-counted every turn.
    private var lastInputTokens: Int = 0
    private var lastOutputTokens: Int = 0
    private var lastCacheCreationTokens: Int = 0
    private var lastCacheReadTokens: Int = 0
    /// Latest line timestamp that carried a non-zero usage. We use this
    /// to disambiguate when reverse-tail backfill ingests historical lines
    /// out of order — only the newest-by-timestamp usage wins for the
    /// `last*` fields. Cumulative totals still sum every ingest as before.
    private var lastUsageAt: Date? = nil
    /// Latest `message.model` value the staging parser saw. The activity
    /// strip's cost estimator uses this — sessions can switch mid-stream
    /// via `/model` and the most recent rate should apply going forward.
    private var modelHint: String? = nil
    /// Timestamp of the most-recently ingested line. The chat's
    /// "thinking" indicator pulses when this is within the activity
    /// window (Date() - 30s).
    private var lastEventAt: Date? = nil
    /// Bumps on every ingest that produced a delta. The @MainActor poll
    /// task uses this to short-circuit "nothing changed" commits.
    private var updateCounter: UInt64 = 0
    /// Cached derived state rebuilt on snapshot() request. Invalidated
    /// whenever sortedMessages or planText changes.
    private var cachedSnapshot: SessionChatStore.ChatSnapshot = .empty
    private var cachedCounter: UInt64 = 0

    // --- Incremental derived state (hardening sprint) ----------------------
    // Sources / artifacts / lowercased bodies are maintained on each
    // ingest rather than recomputed during snapshot(). Trade: each ingest
    // does O(1) extra work; snapshot() drops from O(N + M×candidate.length)
    // to O(K log K) for the sources sort + O(M × 50) for the plan-step
    // scan. With N=5,536 and M=24, this is a measurable difference
    // during the backfill window where the snapshot() poll fires every
    // 16 ms and the original implementation rebuilt all four derived
    // arrays from scratch every tick.

    private var fileCounts: [String: Int] = [:]
    private var urlCounts: [String: Int] = [:]
    private var artifactPaths: [String] = []          // insertion-order
    private var seenArtifactPaths: Set<String> = []

    /// Last ~200 assistant-message bodies, lowercased once at ingest time
    /// and reused for plan-step completion detection. The original code
    /// called `.lowercased()` on every candidate inside the M-step loop;
    /// for sessions with long assistant bodies this allocated tens of MB
    /// per snapshot during backfill.
    private var lowercasedAssistantBodies: [String] = []
    private static let maxCachedAssistantBodies = 200

    /// Step-completion scan window — only the most-recent N assistant
    /// bodies are checked. Steps from late in the conversation are the
    /// ones that matter for the "is this complete" heuristic; older
    /// bodies that already exist on screen don't need to be re-scanned
    /// every tick.
    private static let stepCompletionScanWindow = 50

    /// Snapshot-rebuild throttle. During a high-rate backfill the
    /// `updateCounter` changes on every ingest; without a throttle, the
    /// 16 ms commit task rebuilds derived state on every tick. We cap
    /// rebuilds to once per `minRebuildIntervalNanos` so the actor can
    /// spend its time ingesting rather than re-publishing. Steady-state
    /// (low ingest rate) is unaffected — the first rebuild after a quiet
    /// window is always serviced immediately.
    private var lastSnapshotRebuildNS: UInt64 = 0
    private static let minRebuildIntervalNanos: UInt64 = 100_000_000  // 100 ms
    private static let maxRetainedMessages: Int = chatRecentMessageLimit
    private var retainedMessageLimit: Int = maxRetainedMessages

    func ingest(_ line: ParsedLine) {
        guard apply(line) else { return }
        updateCounter &+= 1
    }

    func expandRetainedMessageLimit(to limit: Int) {
        retainedMessageLimit = max(retainedMessageLimit, limit)
    }

    func ingestBatch<S: Sequence>(_ lines: S) where S.Element == ParsedLine {
        var changed = false
        for line in lines {
            changed = apply(line) || changed
        }
        guard changed else { return }
        updateCounter &+= 1
    }

    @discardableResult
    private func apply(_ line: ParsedLine) -> Bool {
        var anyAppended = false
        for msg in line.messages {
            guard !seenIds.contains(msg.id) else { continue }
            seenIds.insert(msg.id)
            let idx = insertIndex(for: msg)
            sortedMessages.insert(msg, at: idx)
            ingestIntoDerivedIndexes(msg)
            anyAppended = true
        }
        let hasUsage =
            line.deltaInputTokens != 0
            || line.deltaOutputTokens != 0
            || line.deltaCacheCreationTokens != 0
            || line.deltaCacheReadTokens != 0
        if anyAppended || hasUsage || (line.model?.isEmpty == false) {
            // Activity tracking: the metadata strip uses this to decide
            // whether the "thinking" indicator should pulse. We keep
            // the latest line's timestamp (not Date()) so a backfill of
            // historical messages doesn't falsely show the agent as
            // active.
            if let stamp = line.messages.map(\.at).max() {
                if lastEventAt == nil || stamp > lastEventAt! {
                    lastEventAt = stamp
                }
            } else if hasUsage, lastEventAt == nil || line.timestamp > lastEventAt! {
                lastEventAt = line.timestamp
            }
            totalInputTokens += line.deltaInputTokens
            totalOutputTokens += line.deltaOutputTokens
            totalCacheCreationTokens += line.deltaCacheCreationTokens
            totalCacheReadTokens += line.deltaCacheReadTokens
            // Track the newest-by-timestamp usage separately for the
            // context-window meter. Only assistant turns carry usage on
            // Claude — gating on a non-zero delta keeps tool-result and
            // user lines from clobbering the last real turn.
            let usageStamp = line.messages.map(\.at).max() ?? line.timestamp
            if hasUsage, lastUsageAt == nil || usageStamp >= lastUsageAt! {
                lastUsageAt = usageStamp
                lastInputTokens = line.deltaInputTokens
                lastOutputTokens = line.deltaOutputTokens
                lastCacheCreationTokens = line.deltaCacheCreationTokens
                lastCacheReadTokens = line.deltaCacheReadTokens
            }
            // Take the latest non-empty model hint. Reverse-tail ingests
            // can arrive out of order, but the latest timestamp wins
            // because we re-walk this on every snapshot rebuild anyway.
            if let m = line.model, !m.isEmpty {
                modelHint = m
            }
        }
        trimToRecentLimitIfNeeded()
        return anyAppended || hasUsage || (line.model?.isEmpty == false)
    }

    func setPlanText(_ text: String?) {
        guard planText != text else { return }
        planText = text
        updateCounter &+= 1
    }

    /// v0.7.8: latest Codex SDK `todo_list` event snapshot. Each event
    /// the SDK fires REPLACES the list (the SDK doesn't emit deltas;
    /// the latest emission is the canonical state), so the setter
    /// overwrites rather than merging.
    func setCodexTodos(_ todos: [CodexTodoItem]) {
        guard codexTodos != todos else { return }
        codexTodos = todos
        updateCounter &+= 1
    }

    /// v0.23 (Chat V2): per-turn lifecycle transition. Idempotent on
    /// no-op transitions so ingestors can call freely without bumping
    /// the snapshot counter on every line.
    func setCurrentTurnState(_ state: TurnState) {
        guard currentTurnState != state else { return }
        currentTurnState = state
        updateCounter &+= 1
    }

    /// Bump the published snapshot without changing parsed transcript state.
    /// Used when parallel store state such as `pendingPermissionPrompt`
    /// changes; WS subscribers read that field while encoding the snapshot.
    func touch() {
        updateCounter &+= 1
    }

    /// Hardening: clear all accumulated state without re-instantiating
    /// the actor. Called by `SessionChatStore.start()` when re-entering
    /// after a prior `stop()` so untracked in-flight ingests can't bleed
    /// stale messages into a fresh session.
    func reset() {
        sortedMessages.removeAll(keepingCapacity: false)
        seenIds.removeAll(keepingCapacity: false)
        planText = nil
        codexTodos.removeAll(keepingCapacity: false)
        fileCounts.removeAll(keepingCapacity: false)
        urlCounts.removeAll(keepingCapacity: false)
        artifactPaths.removeAll(keepingCapacity: false)
        seenArtifactPaths.removeAll(keepingCapacity: false)
        lowercasedAssistantBodies.removeAll(keepingCapacity: false)
        totalInputTokens = 0
        totalOutputTokens = 0
        totalCacheCreationTokens = 0
        totalCacheReadTokens = 0
        lastInputTokens = 0
        lastOutputTokens = 0
        lastCacheCreationTokens = 0
        lastCacheReadTokens = 0
        lastUsageAt = nil
        modelHint = nil
        lastEventAt = nil
        currentTurnState = .idle
        cachedSnapshot = .empty
        cachedCounter = 0
        updateCounter = 0
        lastSnapshotRebuildNS = 0
        retainedMessageLimit = Self.maxRetainedMessages
    }

    /// Snapshot the current state. Two short-circuit paths:
    /// 1. `cachedCounter == updateCounter` — nothing changed, return cache.
    /// 2. Less than `minRebuildIntervalNanos` since the previous rebuild
    ///    AND we already have a non-empty cached snapshot — under
    ///    backfill, this keeps the poller from doing repeated rebuild
    ///    work while ingest is still streaming.
    func snapshot() -> SessionChatStore.ChatSnapshot {
        guard cachedCounter != updateCounter else { return cachedSnapshot }
        let nowNS = DispatchTime.now().uptimeNanoseconds
        if cachedCounter != 0,
           nowNS &- lastSnapshotRebuildNS < Self.minRebuildIntervalNanos {
            // Within the throttle window — defer the rebuild. The commit
            // loop will call snapshot() again on the next 16 ms tick and
            // we'll eventually fall through this guard.
            return cachedSnapshot
        }

        // 1) items[] — has to be a full rebuild because ChatItemBuilder's
        //    run-grouping depends on chronological order.
        var builder = ChatItemBuilder()
        for msg in sortedMessages {
            builder.ingest(msg)
        }
        builder.flushPending()
        let items = builder.items

        // 2) planSteps — bounded scan against precomputed lowercased
        //    bodies. The candidate-extraction pass walks items once
        //    (skipping non-assistant), but the completion check no longer
        //    re-lowercases full bodies per step.
        let steps = computePlanStepsIncremental(items: items)

        // 3) source entries — sort the incremental dicts; no full scan.
        var sources: [SourceEntry] = []
        for (path, count) in fileCounts.sorted(by: { $0.value > $1.value }) {
            sources.append(SourceEntry(
                id: "f:\(path)", kind: .file, label: path,
                payload: path, count: count
            ))
        }
        for (url, count) in urlCounts.sorted(by: { $0.value > $1.value }) {
            sources.append(SourceEntry(
                id: "u:\(url)", kind: .url, label: url,
                payload: url, count: count
            ))
        }

        // 4) artifacts — maintained as an insertion-ordered list.
        let artifacts = artifactPaths.map { ArtifactEntry(path: $0) }

        cachedSnapshot = SessionChatStore.ChatSnapshot(
            items: items,
            // v0.5.3: include the raw chronological message list so the
            // daemon's /transcript endpoint can serve it from the same
            // cache pile-up that /chat-snapshot reads. We copy
            // `sortedMessages` rather than dedup-extract from items
            // because items has run-grouping applied that drops the
            // 1:1 mapping.
            messages: sortedMessages,
            planSteps: steps,
            sourceEntries: sources,
            artifactEntries: artifacts,
            codexTodos: codexTodos,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalCacheCreationTokens: totalCacheCreationTokens,
            totalCacheReadTokens: totalCacheReadTokens,
            lastInputTokens: lastInputTokens,
            lastOutputTokens: lastOutputTokens,
            lastCacheCreationTokens: lastCacheCreationTokens,
            lastCacheReadTokens: lastCacheReadTokens,
            modelHint: modelHint,
            lastEventAt: lastEventAt,
            updateCounter: updateCounter,
            currentTurnState: currentTurnState
        )
        cachedCounter = updateCounter
        lastSnapshotRebuildNS = nowNS
        return cachedSnapshot
    }

    // MARK: - Incremental derived-state maintenance

    /// Update fileCounts/urlCounts/artifactPaths/lowercasedAssistantBodies
    /// in O(1) (amortized) on each new message. The original implementation
    /// rebuilt these by scanning all of sortedMessages on every snapshot.
    private func ingestIntoDerivedIndexes(_ msg: ChatMessage) {
        switch msg.kind {
        case .assistantText:
            lowercasedAssistantBodies.append(msg.body.lowercased())
            if lowercasedAssistantBodies.count > Self.maxCachedAssistantBodies {
                let drop = lowercasedAssistantBodies.count - Self.maxCachedAssistantBodies
                lowercasedAssistantBodies.removeFirst(drop)
            }
        case .toolCall:
            let trimmed = msg.body.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            switch msg.title {
            case "Read", "Edit":
                fileCounts[trimmed, default: 0] += 1
            case "Write":
                fileCounts[trimmed, default: 0] += 1
                let ext = (trimmed as NSString).pathExtension.lowercased()
                if Self.artifactExtensions.contains(ext),
                   !seenArtifactPaths.contains(trimmed) {
                    seenArtifactPaths.insert(trimmed)
                    artifactPaths.append(trimmed)
                }
            case "Glob", "Grep":
                fileCounts[trimmed, default: 0] += 1
            // v0.23 (Chat V2 — T12): provider-specific tool names for
            // web search. Claude CLI emits `WebFetch` / `WebSearch`
            // (CamelCase); Codex SDK emits `web_search` (snake_case)
            // through the SDK event stream; Antigravity agentapi emits
            // `web_search` too. Map all variants to urlCounts so the V2
            // Deep Research trace's citations footer pulls URLs out of
            // every provider's tool results uniformly.
            case "WebFetch", "WebSearch", "web_search", "WebFetchTool", "WebSearchTool":
                urlCounts[trimmed, default: 0] += 1
            default:
                break
            }
        case .userText, .toolResult, .meta:
            break
        }
    }

    private func trimToRecentLimitIfNeeded() {
        guard sortedMessages.count > retainedMessageLimit else { return }
        let dropCount = sortedMessages.count - retainedMessageLimit
        for message in sortedMessages.prefix(dropCount) {
            seenIds.remove(message.id)
        }
        sortedMessages.removeFirst(dropCount)
        rebuildDerivedIndexesFromRetainedMessages()
    }

    private func rebuildDerivedIndexesFromRetainedMessages() {
        fileCounts.removeAll(keepingCapacity: true)
        urlCounts.removeAll(keepingCapacity: true)
        artifactPaths.removeAll(keepingCapacity: true)
        seenArtifactPaths.removeAll(keepingCapacity: true)
        lowercasedAssistantBodies.removeAll(keepingCapacity: true)
        for msg in sortedMessages {
            ingestIntoDerivedIndexes(msg)
        }
    }

    // MARK: - Plan-step extraction

    private func computePlanStepsIncremental(items: [ChatItem]) -> [PlanStep] {
        // Step candidates come from planText first, then assistant
        // messages in chronological order, capped at 24.
        var stepTexts: [String] = []
        var seen: Set<String> = []
        let plan = planText ?? ""
        for step in Self.extractStepCandidates(from: plan) {
            let key = String(step.lowercased().prefix(40))
            if !seen.contains(key) {
                seen.insert(key)
                stepTexts.append(step)
                if stepTexts.count >= 24 { break }
            }
        }
        if stepTexts.count < 24 {
            for item in items {
                if case .message(let m) = item, m.kind == .assistantText {
                    for step in Self.extractStepCandidates(from: m.body) {
                        let key = String(step.lowercased().prefix(40))
                        if !seen.contains(key) {
                            seen.insert(key)
                            stepTexts.append(step)
                            if stepTexts.count >= 24 { break }
                        }
                    }
                    if stepTexts.count >= 24 { break }
                }
            }
        }

        // Completion check: scan only the most-recent N lowercased
        // assistant bodies (already cached at ingest time). Plus the
        // planText, lowercased once.
        let recentBodies = lowercasedAssistantBodies
            .suffix(Self.stepCompletionScanWindow)
        let lcPlan = plan.isEmpty ? "" : plan.lowercased()
        return stepTexts.enumerated().map { idx, text in
            let needle = String(text.lowercased().prefix(30))
            let needleLen = needle.count
            // Self-match guard: skip the body whose own first-30 chars
            // are the needle (the body the step came from).
            let inRecent = recentBodies.contains { body in
                guard body.contains(needle) else { return false }
                // Cheap self-match filter — if the recent body STARTS
                // with the needle and is short enough to be just the
                // step text repeated, treat as self-reference. Otherwise
                // a later mention counts.
                if body.hasPrefix(needle) && body.count <= needleLen + 4 {
                    return false
                }
                return true
            }
            let inPlan = !lcPlan.isEmpty && lcPlan.contains(needle)
                && !(lcPlan.hasPrefix(needle) && lcPlan.count <= needleLen + 4)
            return PlanStep(
                id: "step-\(idx)", text: text, isComplete: inRecent || inPlan
            )
        }
    }

    /// Forwarder kept on StagingParser for call-site brevity; the
    /// canonical implementation lives in `ChatMessageOrdering` in the
    /// Shared module so unit tests can exercise it directly.
    private static func extractStepCandidates(from body: String) -> [String] {
        ChatMessageOrdering.extractStepCandidates(from: body)
    }

    private static let artifactExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "png", "jpg", "jpeg", "gif", "svg", "webp", "tiff",
        "mp4", "mov", "mp3", "wav",
        "csv", "tsv",
        "zip", "tar", "gz",
    ]

    /// Binary-search insertion index keeping `sortedMessages` ordered by
    /// `(at, kindRank, id)` via the shared `ChatMessageOrdering`. The
    /// kind-based tiebreak fixes the previous `(at, id)` design that
    /// relied on `"call:" < "result:"` lexicographic ordering — fragile
    /// against any future change to Anthropic's id prefixes.
    private func insertIndex(for msg: ChatMessage) -> Int {
        var lo = 0
        var hi = sortedMessages.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ChatMessageOrdering.precedes(sortedMessages[mid], msg) {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        return lo
    }
}
