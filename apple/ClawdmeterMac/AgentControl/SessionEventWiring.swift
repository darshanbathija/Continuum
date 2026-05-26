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

    public init(
        sessionId: UUID,
        sessionFileURL: URL,
        goal: String?,
        registry: AgentSessionRegistry,
        notifications: NotificationDispatcher? = nil
    ) {
        self.sessionId = sessionId
        self.registry = registry
        self.notifications = notifications
        self.progressTracker = PlanProgressTracker(sessionId: sessionId, registry: registry)

        let captureSessionId = sessionId
        let notificationQueue = notifications
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
        }

        let planNotificationQueue = notifications
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
}
