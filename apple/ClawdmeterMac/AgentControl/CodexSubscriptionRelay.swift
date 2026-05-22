// Daemon-side relay that ingests the Codex SDK observer sidecar's
// stdout (JSON-lines stream_event payloads) and republishes them as a
// Combine publisher subscribers can attach to. Bridges between
// `tools/clawdmeter-codex-sdk/main.mjs` running in observer mode and
// the rest of the Mac daemon (`AgentControlServer`'s WS subscribers,
// inline IDE chat panes, audit log, etc.).
//
// One sidecar process per active session. The session id is the key —
// each Codex session that wants live SDK observation gets its own
// `RelayedSubscription` (sidecar + AsyncStream pair). The relay
// itself is a singleton owned by `AgentControlServer`.
//
// Lifecycle:
//   1. `start(session:workingDirectory:initialPrompt:)` spawns the
//      Node sidecar with the observer agent, sends the initial
//      `{op:"start", workingDirectory, prompt}` op, returns the
//      subscription handle. Caller subscribes to `handle.events`.
//   2. `forwardPrompt(sessionId:prompt:)` writes a new `{op:"start"}`
//      or `{op:"resume", threadId}` to the running sidecar's stdin.
//      Used when a Codex session sends a follow-up message and the
//      relay is already running.
//   3. `stop(sessionId:)` writes `{op:"shutdown"}` to stdin, waits for
//      the sidecar to exit, releases the subscription.
//
// Events are emitted as `RelayEvent` values — a typed wrapper around
// the raw SDK `ThreadEvent` JSON. Consumers either decode the raw JSON
// themselves or use the convenience properties.
//
// **Skeleton-aware**: if `CodexSDKManager.isProvisioned` is false, the
// relay returns a failed subscription immediately rather than spawning
// a Node process. Caller surfaces the "Toggle SDK mode in Settings"
// CTA.

import Foundation
import Combine
import OSLog
import ClawdmeterShared

private let relayLogger = Logger(subsystem: "com.clawdmeter.mac", category: "CodexSubscriptionRelay")

/// One event from the SDK observer sidecar. The relay parses the raw
/// JSON minimally — enough to classify the type — and hands the
/// structured payload through. Consumers do final shape decoding.
public struct CodexRelayEvent: Equatable, Sendable {
    /// Wraps the sidecar's `{type:"stream_event", subscriptionId,
    /// threadId, event}` envelope. Caller cares about `event` (the
    /// SDK's ThreadEvent payload).
    public enum Kind: String, Sendable {
        /// `thread.started` — initial event, includes thread_id.
        case threadStarted = "thread.started"
        /// `turn.started`
        case turnStarted = "turn.started"
        /// `item.started`/`item.updated`/`item.completed` — collapsed
        /// because consumers usually want the same handling regardless
        /// of state (last write wins per item.id).
        case item
        /// `turn.completed` — terminal for the turn, includes usage.
        case turnCompleted = "turn.completed"
        /// `turn.failed`
        case turnFailed = "turn.failed"
        /// `error` — fatal stream error.
        case error
        /// `stream_started` — relay-emitted, not from SDK. Signals
        /// the sidecar accepted the subscribe op.
        case streamStarted = "stream_started"
        /// `stream_done` — relay-emitted, the SDK's turn.completed/
        /// turn.failed/error closed the stream cleanly.
        case streamDone = "stream_done"
        /// `stream_error` — relay-emitted, sidecar hit an exception
        /// rather than completing the turn normally.
        case streamError = "stream_error"
        /// `observer_ready` — relay-emitted on initial sidecar
        /// handshake; not user-visible.
        case observerReady = "observer_ready"
        /// Any event type the relay doesn't recognize. Caller can
        /// inspect raw json to extract.
        case unknown
    }

    public let kind: Kind
    /// `subscriptionId` from the sidecar's stream_event envelope.
    /// Stable for the lifetime of one `runStreamed()` call.
    public let subscriptionId: String?
    /// Thread id once the SDK has assigned one (after `thread.started`).
    public let threadId: String?
    /// Raw JSON dict for the event payload. Always present; never nil.
    public let raw: [String: Any]
    public let receivedAt: Date

    public static func == (lhs: CodexRelayEvent, rhs: CodexRelayEvent) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.subscriptionId == rhs.subscriptionId &&
        lhs.threadId == rhs.threadId &&
        lhs.receivedAt == rhs.receivedAt
    }

    /// Returns the raw JSON payload. The struct declares Sendable but
    /// `[String: Any]` isn't formally Sendable; this accessor exists for
    /// downstream consumers that want a non-property access pattern,
    /// matching `event.rawDict()` shape the ingestor + WS channel use.
    public func rawDict() -> [String: Any] { raw }
}

/// Handle returned by `start()`. Holds the events publisher and a
/// `stop()` closure. Drop the handle to disable forwarding; caller
/// still has to call `relay.stop(sessionId:)` to terminate the
/// sidecar process.
public struct CodexRelaySubscription: Sendable {
    public let sessionId: UUID
    public let events: AsyncStream<CodexRelayEvent>
    fileprivate let processHandle: ProcessHandle
}

/// Erased reference to the underlying Process + Pipes. Held by the
/// relay map, not by the public subscription handle (which is
/// Sendable and shouldn't expose mutable process state).
fileprivate final class ProcessHandle: @unchecked Sendable {
    let process: Process
    let stdinPipe: Pipe
    let stdoutPipe: Pipe
    let stderrPipe: Pipe
    let continuation: AsyncStream<CodexRelayEvent>.Continuation
    var lastThreadId: String?
    var lastSubscriptionId: String?

    init(process: Process, stdinPipe: Pipe, stdoutPipe: Pipe, stderrPipe: Pipe,
         continuation: AsyncStream<CodexRelayEvent>.Continuation) {
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.continuation = continuation
    }
}

@MainActor
public final class CodexSubscriptionRelay {

    public static let shared = CodexSubscriptionRelay()

    /// Active sidecar processes keyed by session id.
    private var active: [UUID: ProcessHandle] = [:]

    /// v0.7.4: multi-subscriber fanout. Each session gets a PassthroughSubject
    /// that the stdout reader feeds in addition to the legacy AsyncStream
    /// continuation in `start()`'s return value. iOS WS channel + Mac
    /// SessionChatStore ingestor both subscribe via `subscribe(sessionId:)`
    /// without contending for the single AsyncStream slot.
    private var subjects: [UUID: PassthroughSubject<CodexRelayEvent, Never>] = [:]

    public init() {}

    /// Subscribe to a session's relay events via Combine. Multiple subscribers
    /// per session id are supported; the subject is created lazily and lives
    /// until `stop(sessionId:)` is called.
    public func subscribe(sessionId: UUID) -> AnyPublisher<CodexRelayEvent, Never> {
        subject(for: sessionId).eraseToAnyPublisher()
    }

    private func subject(for sessionId: UUID) -> PassthroughSubject<CodexRelayEvent, Never> {
        if let s = subjects[sessionId] { return s }
        let s = PassthroughSubject<CodexRelayEvent, Never>()
        subjects[sessionId] = s
        return s
    }

    // MARK: - Public API

    /// Spawn a new observer sidecar for the given session and start the
    /// first `runStreamed()` against `initialPrompt`. Returns a
    /// subscription handle the caller can read events from.
    ///
    /// Throws if the SDK isn't provisioned (CodexSDKManager.isProvisioned
    /// is false) or the sidecar can't be spawned. Caller catches and
    /// surfaces the "Toggle SDK mode in Settings → Codex" CTA.
    public func start(
        session: AgentSession,
        workingDirectory: String,
        initialPrompt: String,
        threadId: String? = nil,
        model: String? = nil,
        sandboxMode: String? = nil,
        modelReasoningEffort: String? = nil,
        skipGitRepoCheck: Bool = false
    ) throws -> CodexRelaySubscription {
        if let existing = active[session.id] {
            // A relay is already running for this session. Reuse it by
            // forwarding the new prompt as a `start` op (which kicks
            // off a new runStreamed in the same sidecar process).
            try forwardPrompt(
                handle: existing,
                op: threadId == nil ? "start" : "resume",
                workingDirectory: workingDirectory,
                prompt: initialPrompt,
                threadId: threadId,
                model: model,
                sandboxMode: sandboxMode,
                modelReasoningEffort: modelReasoningEffort,
                skipGitRepoCheck: skipGitRepoCheck,
                deepResearch: session.deepResearch
            )
            // Hand back the existing async stream — events from the new
            // op flow through the same continuation.
            // NOTE: AsyncStream doesn't expose a "subscribe again"
            // primitive. Real iOS clients should multiplex via a
            // PassthroughSubject downstream of the relay if multiple
            // concurrent subscribers are needed for one session. For
            // v0.7.2 we accept "one subscriber per session" — the WS
            // bridge (v0.7.3) lifts that.
            return CodexRelaySubscription(
                sessionId: session.id,
                events: AsyncStream { _ in /* already drained */ },
                processHandle: existing
            )
        }

        guard CodexSDKManager.shared.isProvisioned else {
            throw RelayError.sdkNotProvisioned
        }

        let manager = CodexSDKManager.shared
        guard let nodeBinary = manager.locateNode() else {
            throw RelayError.nodeBinaryMissing
        }
        let mainJS = manager.appSupportDir().appendingPathComponent("main.mjs")
        guard FileManager.default.fileExists(atPath: mainJS.path) else {
            throw RelayError.sidecarScriptMissing
        }

        let process = Process()
        process.executableURL = nodeBinary
        process.arguments = [mainJS.path]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        var continuation: AsyncStream<CodexRelayEvent>.Continuation!
        let stream = AsyncStream<CodexRelayEvent>(bufferingPolicy: .bufferingOldest(512)) { cont in
            continuation = cont
        }

        let handle = ProcessHandle(
            process: process,
            stdinPipe: stdin,
            stdoutPipe: stdout,
            stderrPipe: stderr,
            continuation: continuation
        )

        try process.run()

        relayLogger.info("Codex relay spawned sidecar pid=\(process.processIdentifier) for session=\(session.id.uuidString, privacy: .public)")

        // Set up the stdout reader on a background queue. Each line
        // becomes a CodexRelayEvent and gets yielded into the stream.
        attachStdoutReader(handle: handle, sessionId: session.id)

        // v0.8 QA: drain stderr too. The Node SDK writes diagnostic
        // text (auth errors, network failures, deprecation warnings)
        // to stderr. Without a reader, the pipe fills at ~64KB and
        // the sidecar blocks on its next stderr write — manifests as
        // chat hanging silently with no assistant response. Log every
        // stderr line so SDK failures are visible in Console.
        attachStderrReader(handle: handle, sessionId: session.id)

        // Send the agent header — observer mode.
        try writeLine(to: stdin, ["agent": "observer"])

        // Send the first op (start or resume).
        try forwardPrompt(
            handle: handle,
            op: threadId == nil ? "start" : "resume",
            workingDirectory: workingDirectory,
            prompt: initialPrompt,
            threadId: threadId,
            model: model,
            sandboxMode: sandboxMode,
            modelReasoningEffort: modelReasoningEffort,
            skipGitRepoCheck: skipGitRepoCheck,
            deepResearch: session.deepResearch
        )

        // Track the sidecar so subsequent prompts can reuse it.
        active[session.id] = handle

        // v0.8 QA: do NOT tie cleanup to the AsyncStream's continuation
        // termination. Chat-mode callers (AgentControlServer.sendChatSDKPrompt)
        // consume events via the Combine subject (CodexSDKEventIngestor) and
        // discard the AsyncStream's CodexRelaySubscription — that caused the
        // continuation to terminate immediately, firing cleanupIfActive, which
        // sent `{op:"shutdown"}` to the sidecar one tick after `{op:"start"}`.
        // Net effect: sidecar shut down before the SDK could respond. Cleanup
        // is now strictly explicit (stop / teardownSDKChat / app-quit reaper).
        //
        // v0.8 QA F3: BUT we DO need to react to natural process death —
        // if the Node sidecar crashes or exits, we need to remove
        // active[sessionId] so isActive() returns false and the next
        // user send respawns a fresh sidecar. Without this, follow-up
        // sends write to a dead pipe and silently fail. terminationHandler
        // runs on a background queue when the process exits for ANY
        // reason (graceful stop, crash, signal). MainActor-hop to mutate
        // the actor-isolated state.
        let sessionId = session.id
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only clean up if THIS handle is still the active one —
                // a concurrent stop() may have already swapped it.
                if self.active[sessionId] === handle {
                    self.active.removeValue(forKey: sessionId)
                }
                if let subject = self.subjects.removeValue(forKey: sessionId) {
                    subject.send(completion: .finished)
                }
                handle.continuation.finish()
                relayLogger.info("Codex relay sidecar exited for session=\(sessionId.uuidString, privacy: .public); active map cleared")
            }
        }

        return CodexRelaySubscription(
            sessionId: session.id,
            events: stream,
            processHandle: handle
        )
    }

    /// Forward a new prompt to a session that already has a running
    /// sidecar. Mirrors the SDK's `thread.runStreamed()` semantics — a
    /// new turn on the same thread.
    public func forwardPrompt(
        sessionId: UUID,
        workingDirectory: String,
        prompt: String,
        threadId: String? = nil,
        skipGitRepoCheck: Bool = false,
        deepResearch: Bool = false
    ) throws {
        guard let handle = active[sessionId] else {
            throw RelayError.notSubscribed
        }
        try forwardPrompt(
            handle: handle,
            op: threadId == nil ? "start" : "resume",
            workingDirectory: workingDirectory,
            prompt: prompt,
            threadId: threadId,
            model: nil,
            sandboxMode: nil,
            modelReasoningEffort: nil,
            skipGitRepoCheck: skipGitRepoCheck,
            deepResearch: deepResearch
        )
    }

    /// Stop the sidecar for a session. Sends `{op:"shutdown"}` and
    /// waits up to 3s for graceful exit before SIGTERM.
    public func stop(sessionId: UUID) async {
        guard let handle = active.removeValue(forKey: sessionId) else { return }
        do {
            try writeLine(to: handle.stdinPipe, ["op": "shutdown"])
        } catch {
            // Pipe write failed — sidecar may already be dead. Terminate.
        }
        // Wait up to 3s for graceful exit on a background thread.
        let exited = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline {
                    if !handle.process.isRunning {
                        cont.resume(returning: true); return
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                cont.resume(returning: false)
            }
        }
        if !exited {
            handle.process.terminate()
            // Audit P1 fix: reap the child off-main so it doesn't linger
            // as a zombie. terminate() only sends SIGTERM; without a
            // matching wait the kernel keeps the PID slot until the
            // parent reaps it (or exits).
            let proc = handle.process
            Task.detached { proc.waitUntilExit() }
            relayLogger.info("Codex relay force-terminated sidecar for session=\(sessionId.uuidString, privacy: .public) after 3s")
        }
        handle.continuation.finish()
        // v0.7.4: complete the multi-subscriber subject so downstream
        // ingestor + WS channel sinks tear down cleanly.
        if let subject = subjects.removeValue(forKey: sessionId) {
            subject.send(completion: .finished)
        }
    }

    /// Test/teardown helper. Stops all active sidecars synchronously.
    public func stopAll() async {
        let ids = Array(active.keys)
        for id in ids { await stop(sessionId: id) }
    }

    public func isActive(sessionId: UUID) -> Bool {
        active[sessionId] != nil
    }

    // MARK: - Internals

    private func forwardPrompt(
        handle: ProcessHandle,
        op: String,
        workingDirectory: String,
        prompt: String,
        threadId: String?,
        model: String?,
        sandboxMode: String?,
        modelReasoningEffort: String?,
        skipGitRepoCheck: Bool = false,
        deepResearch: Bool = false
    ) throws {
        var payload: [String: Any] = [
            "op": op,
            "workingDirectory": workingDirectory,
            "prompt": prompt,
        ]
        if let threadId { payload["threadId"] = threadId }
        if let model { payload["model"] = model }
        if let sandboxMode { payload["sandboxMode"] = sandboxMode }
        if let modelReasoningEffort { payload["modelReasoningEffort"] = modelReasoningEffort }
        if skipGitRepoCheck { payload["skipGitRepoCheck"] = true }
        // v0.23 (Chat V2 — T7 Deep Research): when the session has
        // deepResearch=true, the relay enables the SDK's `web_search`
        // tool AND prepends the deep-research contract header to the
        // first user turn. The sidecar's main.mjs:130 reads `cmd.tools`
        // straight into threadOptions and uses `cmd.deepResearchHeader`
        // to front-load the user prompt. Codex SDK has no separate
        // system-instruction field, so the header lives inside the
        // first user turn — the SDK retains it in conversation memory.
        if deepResearch {
            payload["tools"] = ["web_search"]
            if let header = AgentSpawner.loadDeepResearchPrompt() {
                payload["deepResearchHeader"] = header
            }
        }
        try writeLine(to: handle.stdinPipe, payload)
    }

    private func writeLine(to stdin: Pipe, _ payload: [String: Any]) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            throw RelayError.encodeFailed
        }
        var withNewline = data
        withNewline.append(0x0a)
        // Audit P0 fix: never log full prompt / workingDirectory / output
        // text at `.public`. Prompts routinely contain secrets, tokens,
        // and PII; OSLog `.public` makes them readable by anyone with
        // Console.app or sysdiagnose access. Build a redacted summary
        // (op + thread id + lengths + cwd basename) for the public log
        // and stash the full payload under `.private` so a developer
        // who explicitly enables private resolution still gets it.
        let op = (payload["op"] as? String) ?? "?"
        let threadId = (payload["threadId"] as? String) ?? "(new)"
        let promptLen = (payload["prompt"] as? String)?.utf8.count ?? 0
        let cwdBasename = ((payload["workingDirectory"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }) ?? "—"
        let fullPreview = String(data: data, encoding: .utf8) ?? "<binary>"
        relayLogger.info(
            "Codex relay stdin: op=\(op, privacy: .public) thread=\(threadId, privacy: .public) cwd=\(cwdBasename, privacy: .public) promptLen=\(promptLen, privacy: .public) full=\(fullPreview, privacy: .private)"
        )
        try stdin.fileHandleForWriting.write(contentsOf: withNewline)
    }

    private func attachStdoutReader(handle: ProcessHandle, sessionId: UUID) {
        // FileHandle.readabilityHandler runs the closure on a private
        // queue. We accumulate bytes into a line buffer, parse complete
        // lines, and yield events into the AsyncStream.
        var buffer = Data()
        handle.stdoutPipe.fileHandleForReading.readabilityHandler = { [weak handle] fileHandle in
            guard let handle else { return }
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                // EOF — sidecar exited. Drain any remaining bytes,
                // finish the stream.
                handle.continuation.finish()
                fileHandle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            // Process complete lines.
            while let newlineIdx = buffer.firstIndex(of: 0x0a) {
                let lineBytes = buffer.subdata(in: buffer.startIndex..<newlineIdx)
                buffer.removeSubrange(buffer.startIndex...newlineIdx)
                guard !lineBytes.isEmpty else { continue }
                let linePreview = String(data: lineBytes.prefix(200), encoding: .utf8) ?? "<binary>"
                // Audit P0 fix: stdout from the SDK frequently includes
                // model output / tool-call payloads. Log only length +
                // a short prefix at .public; full text stays .private.
                relayLogger.info(
                    "Codex relay stdout session=\(sessionId.uuidString, privacy: .public) bytes=\(lineBytes.count, privacy: .public) preview=\(linePreview, privacy: .private)"
                )
                guard let json = try? JSONSerialization.jsonObject(with: lineBytes) as? [String: Any] else {
                    relayLogger.debug("Codex relay session=\(sessionId.uuidString, privacy: .public): unparseable line, len=\(lineBytes.count)")
                    continue
                }
                let event = Self.classify(json: json, handle: handle)
                handle.continuation.yield(event)
                // v0.7.4: fan out to Combine subscribers (ingestor + WS
                // channel). MainActor hop because `subjects` is isolated
                // to the relay actor; `send` doesn't block.
                Task { @MainActor [weak self] in
                    self?.subjects[sessionId]?.send(event)
                }
            }
        }
    }

    /// Drain the sidecar's stderr so its pipe buffer (~64KB) doesn't
    /// fill and block the Node process on its next write. Lines are
    /// logged at debug/info so SDK failures (auth errors, network
    /// timeouts) are visible in Console without leaking the bytes
    /// back to the chat UI.
    private func attachStderrReader(handle: ProcessHandle, sessionId: UUID) {
        var buffer = Data()
        handle.stderrPipe.fileHandleForReading.readabilityHandler = { [weak handle] fileHandle in
            guard let handle else { return }
            let chunk = fileHandle.availableData
            if chunk.isEmpty {
                fileHandle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            while let newlineIdx = buffer.firstIndex(of: 0x0a) {
                let lineBytes = buffer.subdata(in: buffer.startIndex..<newlineIdx)
                buffer.removeSubrange(buffer.startIndex...newlineIdx)
                guard !lineBytes.isEmpty else { continue }
                let line = String(data: lineBytes, encoding: .utf8) ?? "<non-utf8 \(lineBytes.count) bytes>"
                // Audit P0 fix: stderr can include auth errors / paths /
                // tokens. Length + private payload only.
                relayLogger.info(
                    "Codex relay stderr session=\(sessionId.uuidString, privacy: .public) bytes=\(lineBytes.count, privacy: .public) line=\(line, privacy: .private)"
                )
            }
            _ = handle
        }
    }

    /// Map a raw sidecar JSON line to a `CodexRelayEvent`. Tracks
    /// thread_id and subscription_id on the handle so subsequent events
    /// without those fields can still be threaded back to the right
    /// turn.
    nonisolated private static func classify(json: [String: Any], handle: ProcessHandle) -> CodexRelayEvent {
        let outerType = json["type"] as? String ?? ""
        var subscriptionId = json["subscriptionId"] as? String
        var threadId = json["threadId"] as? String

        // For nested stream_event envelopes, the actual SDK event lives
        // under `event` and the envelope keys carry the routing.
        var raw = json
        var innerType = outerType
        if outerType == "stream_event", let event = json["event"] as? [String: Any] {
            raw = event
            innerType = event["type"] as? String ?? ""
            if let tid = event["thread_id"] as? String { threadId = tid }
        }

        // Persist last-known ids on the handle so subsequent events
        // without explicit threadId still get tagged.
        if let sid = subscriptionId { handle.lastSubscriptionId = sid }
        if let tid = threadId { handle.lastThreadId = tid }
        subscriptionId = subscriptionId ?? handle.lastSubscriptionId
        threadId = threadId ?? handle.lastThreadId

        let kind: CodexRelayEvent.Kind = {
            switch innerType {
            case "thread.started": return .threadStarted
            case "turn.started": return .turnStarted
            case "item.started", "item.updated", "item.completed": return .item
            case "turn.completed": return .turnCompleted
            case "turn.failed": return .turnFailed
            case "error": return .error
            case "stream_started": return .streamStarted
            case "stream_done": return .streamDone
            case "stream_error": return .streamError
            case "observer_ready": return .observerReady
            default: return .unknown
            }
        }()

        return CodexRelayEvent(
            kind: kind,
            subscriptionId: subscriptionId,
            threadId: threadId,
            raw: raw,
            receivedAt: Date()
        )
    }

    /// Cleanup after the async stream ends (subscription dropped) or
    /// the sidecar process exited unexpectedly.
    private func cleanupIfActive(sessionId: UUID, gracefully: Bool) {
        guard let handle = active.removeValue(forKey: sessionId) else { return }
        if handle.process.isRunning {
            if gracefully {
                // Best-effort shutdown signal; if it doesn't take, the
                // process gets reaped on app quit anyway.
                _ = try? writeLine(to: handle.stdinPipe, ["op": "shutdown"])
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak handle] in
                    if let h = handle, h.process.isRunning {
                        h.process.terminate()
                        let proc = h.process
                        Task.detached { proc.waitUntilExit() }
                    }
                }
            } else {
                handle.process.terminate()
                let proc = handle.process
                Task.detached { proc.waitUntilExit() }
            }
        }
    }

    public enum RelayError: Error, LocalizedError {
        case sdkNotProvisioned
        case nodeBinaryMissing
        case sidecarScriptMissing
        case notSubscribed
        case encodeFailed

        public var errorDescription: String? {
            switch self {
            case .sdkNotProvisioned:
                return "Codex SDK not provisioned. Toggle SDK mode in Settings → Codex SDK."
            case .nodeBinaryMissing:
                return "Node binary not found. Install Node 18+ or run tools/download-bundled-node.sh."
            case .sidecarScriptMissing:
                return "Codex SDK sidecar script missing from AppSupport — re-toggle SDK mode."
            case .notSubscribed:
                return "No Codex relay subscription is active for this session."
            case .encodeFailed:
                return "Failed to encode relay command JSON."
            }
        }
    }
}
