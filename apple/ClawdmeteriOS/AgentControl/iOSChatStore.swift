import Foundation
import Combine
import ClawdmeterShared
import OSLog

private let chatStoreLogger = Logger(subsystem: "com.clawdmeter.ios", category: "ChatStore")

/// iOS-side mirror of the Mac's `SessionChatStore`. Phase 2 of the
/// WhatsApp-smooth Sessions plan: the legacy 3-second `GET /chat-snapshot`
/// polling loop is replaced by a long-lived `chat-subscribe` WebSocket
/// subscription. The Mac daemon pushes a coalesced `WireChatSnapshot`
/// frame on each commit window (~100ms); iOS replaces its `@Published`
/// snapshot wholesale and SwiftUI re-renders the live chat List.
///
/// Failure modes & their handling:
///   * Mac is on wireVersion < 5 (chatSubscribeMinimum) — stay on HTTP
///     polling so a Mac that hasn't been updated yet keeps working.
///   * WS connect fails or drops mid-stream — reconnect with exponential
///     backoff 1→30s with jitter, resuming with a fresh subscribe (full
///     snapshot on first frame).
///   * `consecutiveWSFailures` exceeds the threshold — fall back to HTTP
///     polling for `httpFallbackCycles` cycles, then retry WS. Prevents
///     stranding the iPhone in "disconnected" state on a flapping daemon.
///   * Background → foreground — explicit reconnect; the OS suspends WS
///     during background and resumed frames may be stale.
///
/// The HTTP `refresh()` path is kept on the type and used by both the
/// fallback ladder and external one-shot callers.
///
/// Memory: bounded to LRU-2 stores via `iOSChatStoreCache` (T42).
@MainActor
public final class iOSChatStore: ObservableObject {
    @Published public private(set) var snapshot: WireChatSnapshot
    public let sessionId: UUID

    private weak var client: AgentControlClient?
    private var subscribeTask: Task<Void, Never>?
    private var fallbackPollTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?
    private var wsTask: URLSessionWebSocketTask?
    private var consecutiveWSFailures: Int = 0

    /// Time of the last successful frame (WS or HTTP). Used to decide
    /// whether to force a resync on foreground.
    private var lastFrameAt: Date = .distantPast

    /// Exponential-backoff schedule between WS reconnect attempts.
    /// Capped at 30s with a small random jitter to avoid thundering-herd
    /// reconnects when many sessions reconnect simultaneously.
    public static let backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    /// After this many consecutive WS failures, fall back to HTTP polling
    /// for `httpFallbackCycles` cycles before retrying WS. Keeps the
    /// iPhone usable when the daemon's WS port is flapping but HTTP
    /// still works (e.g. a misbehaving listener that crashes only the
    /// WS thread).
    public static let wsFailureFallbackThreshold: Int = 3

    /// Number of 3-second HTTP polls performed during a fallback cycle
    /// before the store retries the WS subscription.
    public static let httpFallbackCycles: Int = 3

    /// Idle threshold for foreground-resync. If the last frame is older
    /// than this when the app returns from background, the store
    /// reconnects.
    public static let foregroundResyncThreshold: TimeInterval = 30

    public init(sessionId: UUID, client: AgentControlClient) {
        self.sessionId = sessionId
        self.client = client
        self.snapshot = WireChatSnapshot(
            sessionId: sessionId,
            items: [],
            planSteps: [],
            sourceEntries: [],
            artifactEntries: [],
            totalInputTokens: 0,
            totalOutputTokens: 0,
            lastEventAt: nil,
            updateCounter: 0
        )
    }

    deinit {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func start() {
        guard subscribeTask == nil, fallbackPollTask == nil else { return }
        installForegroundObserver()
        subscribeTask = Task { [weak self] in
            await self?.runSubscriptionLoop()
        }
    }

    public func stop() {
        subscribeTask?.cancel()
        subscribeTask = nil
        fallbackPollTask?.cancel()
        fallbackPollTask = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }

    /// HTTP one-shot snapshot fetch. Preserved for callers outside the
    /// subscribe loop (and used by the fallback ladder).
    @MainActor
    public func refresh() async {
        guard let client else { return }
        if let fetched = await client.fetchChatSnapshot(sessionId: sessionId) {
            // Apply only if the snapshot is genuinely newer. updateCounter
            // is now the real chat cursor (Phase 0a); we still compare
            // items in case an older Mac (< wireVersion 5) is replying
            // with the legacy `session.lastEventSeq` counter that doesn't
            // bump on chat changes.
            if fetched.updateCounter > snapshot.updateCounter || fetched.items != snapshot.items {
                self.snapshot = fetched
                self.lastFrameAt = Date()
            }
        }
    }

    // MARK: - Subscription loop

    private func runSubscriptionLoop() async {
        while !Task.isCancelled {
            // P2-iOS-4: bail out completely when the client has been
            // deallocated (user unpaired, re-paired, or scene torn down).
            // The previous loop kept spinning forever in HTTP fallback
            // even after the client was nil because `weak` guards only
            // existed inside `openAndStreamWS`/`refresh`, not at the
            // top of the loop.
            guard client != nil else {
                chatStoreLogger.info("chat-subscribe: client deallocated, exiting loop")
                stop()
                return
            }
            // Wire-version gate. If the Mac is too old for chat-subscribe,
            // stay on the HTTP fallback indefinitely. The fallback ladder
            // periodically rechecks (a Mac upgrade lands → next cycle
            // tries WS).
            if let wire = client?.serverWireVersion, wire < AgentControlWireVersion.chatSubscribeMinimum {
                chatStoreLogger.debug("chat-subscribe: Mac wireVersion=\(wire); using HTTP fallback")
                await runHTTPFallbackCycles(reason: "wire-too-old")
                continue
            }
            do {
                try await openAndStreamWS()
                consecutiveWSFailures = 0
            } catch {
                consecutiveWSFailures += 1
                chatStoreLogger.debug("chat-subscribe error #\(self.consecutiveWSFailures): \(error.localizedDescription)")
                if consecutiveWSFailures >= Self.wsFailureFallbackThreshold {
                    await runHTTPFallbackCycles(reason: "ws-failures")
                    // After fallback cycles complete, reset the counter so
                    // a single transient WS error after recovery doesn't
                    // jump back into fallback.
                    consecutiveWSFailures = 0
                    continue
                }
                let delay = backoffDelay(for: consecutiveWSFailures)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func openAndStreamWS() async throws {
        guard let client,
              let host = client.host,
              let token = client.token,
              let url = URL(string: "ws://\(AgentControlClient.urlHostLiteral(host)):\(client.wsPort)/")
        else { throw URLError(.badURL) }

        let task = URLSession.shared.webSocketTask(with: URLRequest(url: url, timeoutInterval: 8))
        wsTask = task
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            // Don't clobber if a newer task has already been installed.
            if wsTask === task { wsTask = nil }
        }
        task.resume()

        // Send the chat-subscribe envelope as the first frame. The Mac
        // daemon's `routeWSSubscription` dispatcher reads this, validates
        // the bearer, looks up the session, and starts pushing snapshots.
        let envelope: [String: Any] = [
            "op": "chat-subscribe",
            "token": token,
            "sessionId": sessionId.uuidString
        ]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        try await task.send(.data(body))
        chatStoreLogger.info("chat-subscribe opened for session \(self.sessionId.uuidString, privacy: .public)")

        // Receive snapshot frames until the connection drops or the task
        // is cancelled. The daemon sends JSON text frames; the iOS side
        // applies each one wholesale (full snapshot, no delta encoding in
        // v1 per Codex D6).
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw error
            }
            let data: Data
            switch message {
            case .data(let d):
                data = d
            case .string(let s):
                data = Data(s.utf8)
            @unknown default:
                continue
            }
            if let fetched = try? decoder.decode(WireChatSnapshot.self, from: data) {
                if fetched.updateCounter > snapshot.updateCounter || fetched.items != snapshot.items {
                    self.snapshot = fetched
                    self.lastFrameAt = Date()
                }
            }
        }
    }

    /// Run a bounded sequence of HTTP `refresh()` polls before attempting
    /// to re-open the WS subscription. Bounded because we want to recover
    /// to the cheap WS path as soon as the daemon is healthy again.
    ///
    /// P2-iOS-5: the 3-second `Task.sleep` was interruptible by Task
    /// cancellation (which throws CancellationError) but the `try?`
    /// swallowed it, so foregrounding the app left HTTP fallback stuck
    /// for the rest of the sleep. Drop the `try?` and let cancellation
    /// short-circuit the sleep so the caller can re-enter the WS path.
    private func runHTTPFallbackCycles(reason: String) async {
        chatStoreLogger.info("chat-subscribe: HTTP fallback (reason=\(reason, privacy: .public))")
        for _ in 0..<Self.httpFallbackCycles {
            if Task.isCancelled { return }
            await refresh()
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            } catch {
                // CancellationError — caller cancelled (e.g., scenePhase
                // → active or wsTask reset). Return immediately so the
                // outer loop can try WS again.
                return
            }
        }
    }

    private func backoffDelay(for attempt: Int) -> TimeInterval {
        let idx = min(attempt - 1, Self.backoffSchedule.count - 1)
        let base = Self.backoffSchedule[max(0, idx)]
        // Add 0-20% jitter so a herd of sessions doesn't reconnect in
        // lockstep on a daemon restart.
        let jitter = base * Double.random(in: 0...0.2)
        return base + jitter
    }

    // MARK: - Background/foreground

    private func installForegroundObserver() {
        guard foregroundObserver == nil else { return }
        // UIApplication.didBecomeActiveNotification — observed via name to
        // avoid forcing a UIKit import here. Forwards to a private MainActor
        // method that forces a resync if the last frame is stale.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidBecomeActiveNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleForegroundIfStale()
            }
        }
    }

    private func handleForegroundIfStale() {
        let elapsed = Date().timeIntervalSince(lastFrameAt)
        guard elapsed > Self.foregroundResyncThreshold else { return }
        chatStoreLogger.info("chat-subscribe: foreground resync (\(Int(elapsed))s stale)")
        // Codex fix to P2-iOS-5: cancelling only `wsTask` resyncs the
        // WebSocket path but does nothing while the loop is in HTTP
        // fallback (`wsTask` is nil there). Restart by cancelling the
        // subscription Task itself — its loop body picks `Task.isCancelled`
        // up immediately, the sleep in `runHTTPFallbackCycles` throws
        // CancellationError, and `start()` is re-armed against the
        // resync. wsTask is also closed so any orphan WS frame is dropped.
        wsTask?.cancel(with: .normalClosure, reason: nil)
        subscribeTask?.cancel()
        subscribeTask = nil
        start()
    }
}

/// LRU-2 cache so the iPhone doesn't keep N chat stores alive when the
/// user opens many session detail views. Protected sessions (foregrounded
/// + Live-Activity-pinned) bypass eviction.
///
/// Sessions v2 T42 (mirrors Mac LRU-3 from `SessionsView.protectedSessionIds`).
@MainActor
public final class iOSChatStoreCache {
    public static let shared = iOSChatStoreCache()
    public static let maxStores: Int = 2

    private var stores: [UUID: iOSChatStore] = [:]
    private var accessOrder: [UUID] = []   // LRU; most-recent at end
    private(set) var protectedSessions: Set<UUID> = []

    public init() {}

    public func store(for sessionId: UUID, client: AgentControlClient) -> iOSChatStore {
        if let existing = stores[sessionId] {
            touch(sessionId)
            return existing
        }
        let new = iOSChatStore(sessionId: sessionId, client: client)
        new.start()
        stores[sessionId] = new
        accessOrder.append(sessionId)
        evictIfNeeded()
        return new
    }

    /// Pin a session so it's never evicted by LRU. Used for foregrounded
    /// SessionDetailView + any session referenced by an active Live Activity.
    public func protectSession(_ sessionId: UUID) {
        protectedSessions.insert(sessionId)
    }

    public func unprotectSession(_ sessionId: UUID) {
        protectedSessions.remove(sessionId)
        evictIfNeeded()
    }

    public func close(sessionId: UUID) {
        stores[sessionId]?.stop()
        stores.removeValue(forKey: sessionId)
        accessOrder.removeAll { $0 == sessionId }
    }

    private func touch(_ sessionId: UUID) {
        accessOrder.removeAll { $0 == sessionId }
        accessOrder.append(sessionId)
    }

    private func evictIfNeeded() {
        let evictable = accessOrder.filter { !protectedSessions.contains($0) }
        let excess = (stores.count - protectedSessions.count) - Self.maxStores
        guard excess > 0 else { return }
        for id in evictable.prefix(excess) {
            chatStoreLogger.debug("LRU evict chat store \(id.uuidString, privacy: .public)")
            close(sessionId: id)
        }
    }
}

extension AgentControlClient {
    /// Fetch a chat snapshot for a session over HTTP. Preserved as the
    /// fallback path; the primary path is the `chat-subscribe` WebSocket
    /// long-lived subscription (Phase 2).
    @MainActor
    public func fetchChatSnapshot(sessionId: UUID) async -> WireChatSnapshot? {
        guard let host, let token else { return nil }
        guard let url = URL(string: "http://\(Self.urlHostLiteral(host)):\(httpPort)/sessions/\(sessionId.uuidString)/chat-snapshot") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WireChatSnapshot.self, from: data)
        } catch {
            return nil
        }
    }
}
