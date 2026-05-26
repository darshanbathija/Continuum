import Foundation
import ClawdmeterShared
import OSLog

private let trackerLogger = Logger(subsystem: "com.clawdmeter.mac", category: "PlanProgressTracker")

/// Daemon-side bridge between the JSONL tail (via `SessionEventWiring`)
/// and `AgentSessionRegistry.planProgress`. One instance per session.
///
/// Why this exists separately from `SessionChatStore`: the chat store is
/// LRU-capped on the UI side (only a handful of stores resident at
/// once), but `planProgress` must be available for **every** approved-
/// plan session on the wire so the sidebar bar shows up even on sessions
/// the user hasn't opened in this app run, and so iOS clients (which
/// hit the daemon over HTTP/WS) see progress without forcing the Mac to
/// open the session locally.
///
/// The tracker keeps a small ring buffer of post-approval `ChatMessage`s
/// (capped at 200) and recomputes progress on a 250ms-debounced cadence.
/// Recompute reads `approvedPlanText` + `approvedAt` from the registry
/// each tick, so a late approval flips the bar on without needing any
/// out-of-band notification.
actor PlanProgressTracker {

    private let sessionId: UUID
    private let registry: AgentSessionRegistry
    private var recentMessages: [ChatMessage] = []
    private var scheduledTask: Task<Void, Never>?

    /// Bound on the post-approval message buffer. Plans complete in a
    /// few dozen messages typically; 200 leaves headroom for noisy
    /// sessions without growing unbounded.
    private static let bufferCap = 200

    /// Debounce window — same shape as the staging parser's
    /// `minRebuildIntervalNanos` (100ms there, 250ms here because the
    /// daemon's wire side is less latency-sensitive than the UI's
    /// per-frame commit task).
    private static let recomputeDelayNanos: UInt64 = 250_000_000

    init(sessionId: UUID, registry: AgentSessionRegistry) {
        self.sessionId = sessionId
        self.registry = registry
    }

    /// Ingest one parsed JSONL line. Appends any contained `ChatMessage`s
    /// to the recent buffer and schedules a debounced recompute.
    func ingest(_ parsed: ParsedLine) {
        guard !parsed.messages.isEmpty else { return }
        recentMessages.append(contentsOf: parsed.messages)
        if recentMessages.count > Self.bufferCap {
            recentMessages.removeFirst(recentMessages.count - Self.bufferCap)
        }
        scheduleRecompute()
    }

    private func scheduleRecompute() {
        scheduledTask?.cancel()
        let snapshot = recentMessages
        let sid = sessionId
        let reg = registry
        scheduledTask = Task {
            try? await Task.sleep(nanoseconds: Self.recomputeDelayNanos)
            guard !Task.isCancelled else { return }
            await Self.recompute(sessionId: sid, messages: snapshot, registry: reg)
        }
    }

    @MainActor
    private static func recompute(
        sessionId: UUID,
        messages: [ChatMessage],
        registry: AgentSessionRegistry
    ) async {
        guard let session = registry.session(id: sessionId) else { return }
        guard let approvedText = session.approvedPlanText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !approvedText.isEmpty
        else {
            // Approval was rolled back (or the session never had an
            // approved plan). Make sure the wire field reflects that.
            if session.planProgress != nil {
                do {
                    try await registry.setPlanProgress(id: sessionId, progress: nil)
                } catch {
                    trackerLogger.error("setPlanProgress(nil) write-ahead failed for \(sessionId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }
        // approvedAt comes from the registry's in-memory stamp; on
        // daemon restart it's nil and we fall back to lastEventAt
        // (which is conservative — every retained message is treated
        // as post-approval, which slightly inflates completion).
        let approvedAt = registry.approvedAt(for: sessionId) ?? session.lastEventAt
        let progress = PlanProgressComputer.compute(
            approvedPlanText: approvedText,
            messagesSinceApproval: messages,
            approvedAt: approvedAt
        )
        trackerLogger.debug(
            "recompute session=\(sessionId.uuidString, privacy: .public) completed=\(progress?.completed ?? 0)/\(progress?.total ?? 0)"
        )
        do {
            try await registry.setPlanProgress(id: sessionId, progress: progress)
        } catch {
            trackerLogger.error("setPlanProgress write-ahead failed for \(sessionId.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
