import Foundation
import ClawdmeterShared
import OSLog

private let wiringLogger = Logger(subsystem: "com.clawdmeter.mac", category: "SessionEventWiring")

/// Glues a session's JSONL tail to the `AgentSessionRegistry` (status
/// updates) and `AgentEventStream` (structured events for WS subscribers).
///
/// Lifecycle: created when a session is spawned (POST /sessions). Owns one
/// `JSONLTail` + one `DoneDetector` + one `PlanModeWatcher`. Disposes when
/// the session is deleted (DELETE /sessions/:id).
///
/// E6 addition: when `planReady` or `doneDetected` fires, also fan out to
/// `APNSGatewayPushCoordinator` so the paired iPhone gets a remote-push
/// banner within 2s. The legacy `NotificationDispatcher` queue is still
/// driven so the local-notification surface keeps working when no iPhone
/// is paired.
public final class SessionEventWiring: @unchecked Sendable {

    public let sessionId: UUID

    private let tail: JSONLTail
    private let doneDetector: DoneDetector
    private let planWatcher: PlanModeWatcher
    /// Daemon-side plan-progress recompute. Owns a small post-approval
    /// `ChatMessage` buffer and pushes `PlanProgress` snapshots through
    /// `registry.setPlanProgress(...)` so the sidebar bar advances on
    /// every approved-plan session — including ones whose Mac chat
    /// store is currently evicted from the LRU and ones only ever
    /// opened on a paired iOS client.
    private let progressTracker: PlanProgressTracker

    /// The registry is @MainActor; we hop via Task when calling its mutators.
    private let registry: AgentSessionRegistry
    private let notifications: NotificationDispatcher?
    private let pushCoordinator: APNSGatewayPushCoordinator?

    /// Wall-clock at which this session was spawned. Used by the
    /// E6 `sessionDone` push trigger to skip sessions shorter than the
    /// configured `sessionDoneMinimumRuntimeSeconds` threshold (default
    /// 60s).
    public let startedAt: Date

    public init(
        sessionId: UUID,
        sessionFileURL: URL,
        goal: String?,
        registry: AgentSessionRegistry,
        notifications: NotificationDispatcher? = nil,
        pushCoordinator: APNSGatewayPushCoordinator? = APNSGatewayPushCoordinator.shared,
        startedAt: Date = Date()
    ) {
        self.sessionId = sessionId
        self.registry = registry
        self.notifications = notifications
        self.pushCoordinator = pushCoordinator
        self.startedAt = startedAt
        self.progressTracker = PlanProgressTracker(sessionId: sessionId, registry: registry)

        let captureSessionId = sessionId
        let captureStartedAt = startedAt
        let notificationQueue = notifications
        let captureCoordinatorDone = pushCoordinator
        self.doneDetector = DoneDetector(sessionId: sessionId, goal: goal) { sid, trigger in
            wiringLogger.info("Done fired: session=\(sid.uuidString) trigger=\(trigger)")
            Task { @MainActor in
                // F2-wire: write-ahead failures here are best-effort
                // logged. The done-detector path is fired from a JSONL
                // tail; failing loud would mean a SQLite hiccup blocks
                // status transitions from external events. Surface the
                // breach in logs so telemetry can catch it.
                do {
                    try await registry.updateStatus(id: sid, status: .done)
                } catch {
                    wiringLogger.error("updateStatus(.done) write-ahead failed for \(sid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                AgentEventStream.recordEvent(
                    sessionId: sid,
                    kind: .doneDetected,
                    payload: ["trigger": trigger]
                )
            }
            Task {
                await notificationQueue?.enqueue(
                    sessionId: sid,
                    kind: "session-done",
                    title: "Session done",
                    body: trigger
                )
            }
            // E6: APNS push for "long task done". The 60s minimum runtime
            // gate keeps quick sessions (which the user clearly didn't
            // walk away from) out of the iPhone's notification stream.
            Task {
                await Self.fireSessionDonePush(
                    sessionId: sid,
                    trigger: trigger,
                    startedAt: captureStartedAt,
                    coordinator: captureCoordinatorDone
                )
            }
        }

        let planNotificationQueue = notifications
        let captureCoordinatorPlan = pushCoordinator
        self.planWatcher = PlanModeWatcher(sessionId: sessionId) { sid, planText, _ in
            Task { @MainActor in
                do {
                    try await registry.setPlanText(id: sid, planText: planText)
                } catch {
                    wiringLogger.error("setPlanText write-ahead failed for \(sid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                AgentEventStream.recordEvent(
                    sessionId: sid,
                    kind: .planReady,
                    payload: ["planText": planText]
                )
            }
            Task {
                await planNotificationQueue?.enqueue(
                    sessionId: sid,
                    kind: "plan-ready",
                    title: "Plan ready",
                    body: planText
                )
            }
            // E6: APNS push for plan-approval. Fires immediately — the
            // user-walked-away wedge depends on this banner landing on
            // the iPhone lock screen within ~2 seconds.
            Task {
                await Self.firePlanApprovalPush(
                    sessionId: sid,
                    planText: planText,
                    coordinator: captureCoordinatorPlan
                )
            }
        }

        let doneDetectorRef = doneDetector
        let planWatcherRef = planWatcher
        let progressTrackerRef = progressTracker
        self.tail = JSONLTail(fileURL: sessionFileURL) { json in
            // Run all three watchers per event; they're independent.
            doneDetectorRef.feed(json)
            planWatcherRef.feed(json)
            // Progress tracker only does work post-approval (the recompute
            // bails when `approvedPlanText` is nil), so feeding every line
            // is cheap pre-approval and correct post-approval.
            if let parsed = ParsedLine.from(json: json) {
                Task { await progressTrackerRef.ingest(parsed) }
            }
            _ = captureSessionId  // capture-list satisfaction
        }
    }

    public func start() {
        tail.start()
    }

    public func stop() {
        tail.stop()
    }

    // MARK: - E6 push fan-out

    private static func firePlanApprovalPush(
        sessionId: UUID,
        planText: String,
        coordinator: APNSGatewayPushCoordinator?
    ) async {
        guard let coordinator else { return }
        let body = APNSPushBody(
            kind: "planApproval",
            sessionId: sessionId.uuidString,
            title: "Plan ready",
            body: Self.shortenSummary(planText),
            triggerAt: UInt64(Date().timeIntervalSince1970)
        )
        let outcome = await coordinator.notify(surface: .planApproval, body: body)
        if let outcome {
            wiringLogger.info("APNS plan-approval push outcome=\(outcome.response.rawValue, privacy: .public) elapsed=\(outcome.elapsedSeconds, privacy: .public)s")
        }
    }

    private static func fireSessionDonePush(
        sessionId: UUID,
        trigger: String,
        startedAt: Date,
        coordinator: APNSGatewayPushCoordinator?
    ) async {
        guard let coordinator else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let minRuntime = TimeInterval(APNSGatewaySettings.shared.sessionDoneMinimumRuntimeSeconds)
        guard elapsed >= minRuntime else {
            wiringLogger.debug("Skipping APNS session-done push (elapsed=\(elapsed, privacy: .public)s < \(minRuntime, privacy: .public)s threshold)")
            return
        }
        let body = APNSPushBody(
            kind: "sessionDone",
            sessionId: sessionId.uuidString,
            title: "Session done",
            body: "Trigger: \(trigger). Total runtime: \(Int(elapsed))s.",
            triggerAt: UInt64(Date().timeIntervalSince1970)
        )
        let outcome = await coordinator.notify(surface: .sessionDone, body: body)
        if let outcome {
            wiringLogger.info("APNS session-done push outcome=\(outcome.response.rawValue, privacy: .public) elapsed=\(outcome.elapsedSeconds, privacy: .public)s")
        }
    }

    /// Trim plan text to a single-banner-friendly summary. Banners on
    /// iOS render ~110 chars before truncation; we hard-cap at 100 and
    /// strip newlines so the iPhone preview reads cleanly.
    private static func shortenSummary(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 100 {
            return collapsed
        }
        let prefix = collapsed.prefix(97)
        return "\(prefix)..."
    }
}
