import Foundation
import WatchConnectivity
import ClawdmeterShared
import OSLog

private let bridgeLogger = Logger(subsystem: "com.clawdmeter.ios", category: "WatchPlanBridge")

/// iPhone-side WCSession bridge: pushes plan-waiting state to the paired
/// Watch and accepts approve-plan messages back. Mirrors the existing
/// `WatchTokenBridge` shape.
///
/// Per D10: when the iPhone's notification manager processes a plan-ready
/// event, we update the count + push a fresh applicationContext to the
/// Watch. The Watch's `.accessoryCircular` complication reads from the
/// App Group UserDefaults and updates its badge on next timeline reload.
public final class WatchPlanBridgeIOS: NSObject, WCSessionDelegate {

    public private(set) static var shared = WatchPlanBridgeIOS()

    public let client: AgentControlClient

    @discardableResult
    public static func configure(client: AgentControlClient) -> WatchPlanBridgeIOS {
        if shared.client !== client {
            shared = WatchPlanBridgeIOS(client: client)
        }
        return shared
    }

    public override init() {
        self.client = AgentControlClient()
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    public init(client: AgentControlClient) {
        self.client = client
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Push the latest pending-plan count + previewing fields to the Watch.
    ///
    /// `@MainActor` because the new Sessions-v2 sessions-summary payload
    /// reads `client.sessions` from a main-actor-isolated method; without
    /// this annotation Swift 6 concurrency rejects the call.
    @MainActor
    public func updateContext(count: Int, latestGoal: String?, latestPlanSummary: String?, latestSessionId: UUID?) {
        // P1-Watch-4: merge into the existing applicationContext instead of
        // overwriting it. WatchTokenBridge writes `token` / `usage` /
        // `usageByProvider` into the same context dictionary, and the
        // previous "fresh dict + updateApplicationContext" pattern
        // silently erased whichever bridge pushed last. Explicitly clear
        // plan-specific keys when their inputs go nil so stale values
        // don't linger on the watch when the iPhone reports "no plans
        // waiting".
        var context: [String: Any] = WCSession.default.applicationContext
        context["planWaitingCount"] = count
        if let latestGoal { context["latestGoal"] = latestGoal } else { context["latestGoal"] = nil }
        if let latestPlanSummary { context["latestPlanSummary"] = latestPlanSummary } else { context["latestPlanSummary"] = nil }
        if let id = latestSessionId { context["latestSessionId"] = id.uuidString } else { context["latestSessionId"] = nil }
        // Sessions v2 Phase 6: include the session list snapshot in the
        // same applicationContext push so the watch's list view stays fresh.
        // P2-iOS-2: send an explicit "[]" when there are no live sessions,
        // otherwise the watch's `if let json = context[...]` keeps the
        // previous list visible.
        context["sessionsSummaryJSON"] = encodedSessionsSummary() ?? "[]"
        // v0.7.8: also forward the active Codex SDK session's current
        // in-progress todo so the Watch CodexTaskComplication can render
        // it. Picks the most recently active Codex session and reads its
        // chat-store snapshot's codexTodos; falls back to the first
        // pending if no in_progress exists.
        if let todo = activeCodexTodoHeadline() {
            context["codexCurrentTodo"] = todo
        } else {
            context["codexCurrentTodo"] = nil
        }
        // Drop nil-typed values WCSession refuses to encode.
        context = context.compactMapValues { $0 is NSNull ? nil : $0 }
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            bridgeLogger.debug("updateApplicationContext failed: \(error.localizedDescription)")
        }
    }

    /// Pulls the in-progress (or first pending) todo from the most
    /// recently active Codex session's iOSChatStore. Returns the text
    /// truncated to 18 chars to match the Watch complication's display
    /// budget. Nil when no Codex SDK session has fired a todo_list yet.
    @MainActor
    private func activeCodexTodoHeadline() -> String? {
        let codexSessions = client.sessions
            .filter { $0.agent == .codex && $0.archivedAt == nil }
            .sorted { $0.lastEventAt > $1.lastEventAt }
        for session in codexSessions {
            let store = iOSChatStoreCache.shared.store(for: session.id, client: client)
            let todos = store.snapshot.codexTodos
            let pick = todos.first(where: \.isInProgress) ?? todos.first(where: \.isPending)
            if let todo = pick {
                let text = todo.text
                return text.count > 18 ? String(text.prefix(18)) : text
            }
        }
        return nil
    }

    /// Sessions v2 Phase 6: build a compact `[WatchSessionSummary]` from
    /// the current client.sessions and encode as JSON for transport.
    @MainActor
    private func encodedSessionsSummary() -> String? {
        let summaries = client.sessions
            .filter { $0.archivedAt == nil }
            .prefix(20) // keep payload small for WCSession's 64KB cap
            .map { WatchSessionSummary.from(session: $0, modelCatalog: client.modelCatalog) }
        guard !summaries.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Array(summaries)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        Task { @MainActor in
            await handle(message: message)
            replyHandler(["ok": true])
        }
    }
    public func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        Task { @MainActor in
            await handle(message: message)
        }
    }
    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        Task { @MainActor in
            await handle(message: userInfo)
        }
    }

    @MainActor
    private func handle(message: [String: Any]) async {
        guard let op = message["op"] as? String else { return }
        switch op {
        case "approvePlan":
            if let raw = message["sessionId"] as? String, let id = UUID(uuidString: raw) {
                await client.approvePlan(sessionId: id)
                bridgeLogger.info("Approved plan from Watch for session \(id.uuidString, privacy: .public)")
            }
        case "interrupt":
            // Sessions v2 Phase 6: ESC into the agent pane.
            if let raw = message["sessionId"] as? String, let id = UUID(uuidString: raw) {
                await client.interruptSession(sessionId: id)
                bridgeLogger.info("Interrupted session from Watch: \(id.uuidString, privacy: .public)")
            }
        case "requestVoiceReply":
            // Sessions v2 Phase 6: stub — iPhone-side voice-reply UX lands
            // in a later Phase. For now, log + forward to a notification
            // so the user knows the Watch asked for it.
            if let raw = message["sessionId"] as? String, let id = UUID(uuidString: raw) {
                bridgeLogger.info("Voice-reply request from Watch for session \(id.uuidString, privacy: .public)")
            }
        default:
            bridgeLogger.debug("Unknown WCSession op: \(op, privacy: .public)")
        }
    }
}
