import Foundation
import WatchConnectivity
import Combine
import ClawdmeterShared

/// Receives plan-ready state + session-list snapshot from the paired
/// iPhone via `WCSession` `applicationContext` (latest-wins) + `userInfo`
/// (queued delivery).
///
/// Mirrors the shape of `WatchTokenBridge` (from the existing analytics
/// feature) so the Watch app's wiring is consistent.
///
/// Wire shape:
/// - `planWaitingCount`, `latestGoal`, `latestPlanSummary`, `latestSessionId`
///   (legacy — drives `PlanWaitingComplication` + plan approval flow)
/// - `sessionsSummaryJSON` (Sessions v2 Phase 6 — JSON-encoded array of
///   `WatchSessionSummary` for the sessions list)
public final class WatchPlanBridge: NSObject, ObservableObject, WCSessionDelegate {

    public static let shared = WatchPlanBridge()

    @Published public private(set) var planWaitingCount: Int = 0
    @Published public private(set) var latestGoal: String?
    @Published public private(set) var latestPlanSummary: String?
    @Published public private(set) var latestSessionId: String?
    /// Sessions v2 Phase 6: full session list snapshot for the Watch list
    /// view. Updated when iPhone pushes a new `sessionsSummaryJSON` blob.
    @Published public private(set) var sessionsSummary: [WatchSessionSummary] = []

    private let defaultsSuiteName = "group.76S62SDSD3.com.clawdmeter"
    private lazy var defaults = UserDefaults(suiteName: defaultsSuiteName)

    public override init() {
        super.init()
        loadFromDefaults()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
            // Process whatever context is already there.
            apply(context: session.receivedApplicationContext)
        }
    }

    // MARK: - State

    private func loadFromDefaults() {
        planWaitingCount = defaults?.integer(forKey: "clawdmeter.watch.planWaitingCount") ?? 0
        latestGoal = defaults?.string(forKey: "clawdmeter.watch.latestGoal")
        latestPlanSummary = defaults?.string(forKey: "clawdmeter.watch.latestPlanSummary")
        latestSessionId = defaults?.string(forKey: "clawdmeter.watch.latestSessionId")
    }

    private func apply(context: [String: Any]) {
        WatchTokenBridge.shared.receive(context: context)
        if let count = context["planWaitingCount"] as? Int {
            planWaitingCount = count
            defaults?.set(count, forKey: "clawdmeter.watch.planWaitingCount")
        }
        if let goal = context["latestGoal"] as? String {
            latestGoal = goal
            defaults?.set(goal, forKey: "clawdmeter.watch.latestGoal")
        }
        if let summary = context["latestPlanSummary"] as? String {
            latestPlanSummary = summary
            defaults?.set(summary, forKey: "clawdmeter.watch.latestPlanSummary")
        }
        if let id = context["latestSessionId"] as? String {
            latestSessionId = id
            defaults?.set(id, forKey: "clawdmeter.watch.latestSessionId")
        }
        // Sessions v2 Phase 6: session list snapshot. iPhone sends a
        // JSON-encoded `[WatchSessionSummary]` so the Codable round-trip
        // crosses the WCSession plist boundary cleanly.
        if let json = context["sessionsSummaryJSON"] as? String,
           let data = json.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let summaries = try? decoder.decode([WatchSessionSummary].self, from: data) {
                self.sessionsSummary = summaries
            }
        }
    }

    // MARK: - Approve

    public func approve() {
        guard let sessionId = latestSessionId else { return }
        approve(sessionIdString: sessionId)
    }

    /// Sessions v2 Phase 6: approve a specific session by id (from the
    /// new sessions list, not just the legacy single-plan flow).
    public func approve(sessionId: UUID) {
        approve(sessionIdString: sessionId.uuidString)
    }

    private func approve(sessionIdString: String) {
        let message: [String: Any] = [
            "op": "approvePlan",
            "sessionId": sessionIdString,
        ]
        sendOrQueue(message)
        planWaitingCount = max(0, planWaitingCount - 1)
        defaults?.set(planWaitingCount, forKey: "clawdmeter.watch.planWaitingCount")
    }

    /// Sessions v2 Phase 6: send ESC to the session's tmux pane.
    public func interrupt(sessionId: UUID) {
        sendOrQueue([
            "op": "interrupt",
            "sessionId": sessionId.uuidString,
        ])
    }

    /// Sessions v2 Phase 6: ask iPhone to open dictation for this session.
    /// The actual mic capture happens on iPhone (Watch has its own mic but
    /// the iPhone has the SFSpeechRecognizer + the daemon connection).
    public func requestVoiceReply(sessionId: UUID) {
        sendOrQueue([
            "op": "requestVoiceReply",
            "sessionId": sessionId.uuidString,
        ])
    }

    private func sendOrQueue(_ message: [String: Any]) {
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { _ in }
        } else {
            WCSession.default.transferUserInfo(message)
        }
    }

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        DispatchQueue.main.async {
            self.apply(context: applicationContext)
        }
    }
    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        DispatchQueue.main.async {
            self.apply(context: userInfo)
        }
    }
}
