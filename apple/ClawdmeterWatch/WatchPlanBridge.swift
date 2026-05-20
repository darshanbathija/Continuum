import Foundation
import WatchConnectivity
import Combine
import OSLog
import ClawdmeterShared
#if canImport(WidgetKit)
import WidgetKit
#endif

private let planBridgeLogger = Logger(subsystem: "com.clawdmeter.watch", category: "PlanBridge")

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
        var planWaitingChanged = false
        if let count = context["planWaitingCount"] as? Int {
            if planWaitingCount != count { planWaitingChanged = true }
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
        //
        // P2-Watch-2: log decode failures via os_log instead of `try?`
        // swallowing them — when iPhone ships a payload the watch can't
        // parse, the user just sees a stale list with no breadcrumb.
        if let json = context["sessionsSummaryJSON"] as? String,
           let data = json.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                self.sessionsSummary = try decoder.decode([WatchSessionSummary].self, from: data)
            } catch {
                planBridgeLogger.warning("sessionsSummaryJSON decode failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // v0.6.0 Antigravity task headline.
        if let headline = context["currentTaskHeadline"] as? String {
            defaults?.set(headline, forKey: "clawdmeter.watch.currentTaskHeadline")
        } else {
            defaults?.removeObject(forKey: "clawdmeter.watch.currentTaskHeadline")
        }
        // v0.7.8: Codex SDK in-progress todo headline. Falls back to nil
        // when no active Codex SDK session has emitted a todo_list. Watch
        // CodexTaskComplication reads the same App Group key.
        let priorCodex = defaults?.string(forKey: "clawdmeter.watch.codexCurrentTodo")
        if let codexTodo = context["codexCurrentTodo"] as? String {
            defaults?.set(codexTodo, forKey: "clawdmeter.watch.codexCurrentTodo")
        } else {
            defaults?.removeObject(forKey: "clawdmeter.watch.codexCurrentTodo")
        }
        let codexChanged = priorCodex != (context["codexCurrentTodo"] as? String)
        // P1-Watch-1: push a fresh timeline to the plan-waiting complication
        // whenever the count moves. The complication provider schedules its
        // next refresh 30 minutes out; without this reload the watch face
        // shows a stale "approve" badge until the next timeline tick.
        if planWaitingChanged {
            reloadPlanWaitingComplication()
        }
        if codexChanged {
            reloadCodexTaskComplication()
        }
    }

    private func reloadCodexTaskComplication() {
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "Clawdmeter.codexTask")
#endif
    }

    private func reloadPlanWaitingComplication() {
#if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "ClawdmeterMeter.planWaiting")
#endif
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
        // P1-Watch-1: keep the complication in lockstep with the optimistic
        // decrement so the user sees the count drop immediately.
        reloadPlanWaitingComplication()
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
        // P1-Watch-2: sendMessage's silent error handler dropped approvals
        // when reachability flipped mid-send. transferUserInfo guarantees
        // queued delivery, so fall through to it from inside the error
        // path as well, not just when isReachable is false at call time.
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { _ in
                // The transferUserInfo path is durable across reachability
                // flips, so on send failure resend through it instead of
                // losing the approval.
                WCSession.default.transferUserInfo(message)
            }
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
