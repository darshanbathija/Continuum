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

    /// The registry is @MainActor; we hop via Task when calling its mutators.
    private let registry: AgentSessionRegistry

    public init(
        sessionId: UUID,
        sessionFileURL: URL,
        goal: String?,
        registry: AgentSessionRegistry
    ) {
        self.sessionId = sessionId
        self.registry = registry

        let captureSessionId = sessionId
        self.doneDetector = DoneDetector(sessionId: sessionId, goal: goal) { sid, trigger in
            wiringLogger.info("Done fired: session=\(sid.uuidString) trigger=\(trigger)")
            Task { @MainActor in
                registry.updateStatus(id: sid, status: .done)
                AgentEventStream.recordEvent(
                    sessionId: sid,
                    kind: .doneDetected,
                    payload: ["trigger": trigger]
                )
            }
        }

        self.planWatcher = PlanModeWatcher(sessionId: sessionId) { sid, planText, _ in
            Task { @MainActor in
                registry.setPlanText(id: sid, planText: planText)
                AgentEventStream.recordEvent(
                    sessionId: sid,
                    kind: .planReady,
                    payload: ["planText": planText]
                )
            }
        }

        let doneDetectorRef = doneDetector
        let planWatcherRef = planWatcher
        self.tail = JSONLTail(fileURL: sessionFileURL) { json in
            // Run both watchers per event; they're independent.
            doneDetectorRef.feed(json)
            planWatcherRef.feed(json)
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
