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
        var context: [String: Any] = ["planWaitingCount": count]
        if let latestGoal { context["latestGoal"] = latestGoal }
        if let latestPlanSummary { context["latestPlanSummary"] = latestPlanSummary }
        if let id = latestSessionId { context["latestSessionId"] = id.uuidString }
        // Sessions v2 Phase 6: include the session list snapshot in the
        // same applicationContext push so the watch's list view stays fresh.
        if let json = encodedSessionsSummary() {
            context["sessionsSummaryJSON"] = json
        }
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            bridgeLogger.debug("updateApplicationContext failed: \(error.localizedDescription)")
        }
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
