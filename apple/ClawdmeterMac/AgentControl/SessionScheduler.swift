import Foundation
import ClawdmeterShared
import OSLog

private let schedulerLogger = Logger(subsystem: "com.clawdmeter.mac", category: "SessionScheduler")

/// G15: fires scheduled follow-up prompts at their `fireAt` time by writing
/// into the target session's direct runtime.
///
/// A single `DispatchSourceTimer` is re-armed for the soonest unfired
/// follow-up across all sessions. Whenever the registry's
/// `scheduledFollowUps` collection changes (add / remove / fire), the
/// scheduler recomputes the next deadline and reschedules. Past-due
/// entries that we missed (e.g. app was quit) fire immediately on launch.
///
/// Lifetime: owned by `AppRuntime`, started after the registry loads. The
/// scheduler is a small read-only observer of the registry — it doesn't
/// own state, so re-armed correctly across crashes / restarts.
@MainActor
public final class SessionScheduler {
    public enum DeliveryResult: Sendable, Equatable {
        case delivered
        case unavailable(reason: String)
        case retired(reason: String)
    }

    public typealias FollowUpDeliverer = @MainActor (AgentSession, ScheduledFollowUp) async -> DeliveryResult

    private let registry: AgentSessionRegistry
    private let deliverer: FollowUpDeliverer?

    /// Single re-armable timer. We keep one timer total and adjust its
    /// next-fire deadline whenever follow-ups change — cheaper than one
    /// dispatch source per scheduled item.
    private var timer: DispatchSourceTimer?

    /// Observer token for the registry's @Published change stream.
    private var observerTask: Task<Void, Never>?
    private var inFlightFollowUps: Set<String> = []
    private var followUpRetryAfter: [String: Date] = [:]
    private var followUpsHeldForConfirmation: Set<String> = []
    private let unavailableRetryInterval: TimeInterval

    public init(
        registry: AgentSessionRegistry,
        deliverer: FollowUpDeliverer? = nil,
        unavailableRetryInterval: TimeInterval = 30
    ) {
        self.registry = registry
        self.deliverer = deliverer
        self.unavailableRetryInterval = unavailableRetryInterval
    }

    public func start() {
        guard observerTask == nil else { return }
        // Observe @Published changes via Combine's values async sequence.
        let publisher = registry.$sessions
        let task = Task { [weak self] in
            for await _ in publisher.values {
                self?.reschedule()
            }
        }
        observerTask = task
        reschedule()
    }

    public func stop() {
        observerTask?.cancel()
        observerTask = nil
        timer?.cancel()
        timer = nil
    }

    // MARK: - Reschedule

    /// Look at every unfired follow-up across every session. Find the
    /// soonest. Re-arm the timer. Fire immediately if it's already past-due.
    private func reschedule() {
        timer?.cancel()
        timer = nil

        let now = Date()
        let pending = registry.sessions.flatMap { session -> [(UUID, ScheduledFollowUp, Date)] in
            session.scheduledFollowUps
                .filter { $0.firedAt == nil }
                .compactMap { followUp -> (UUID, ScheduledFollowUp, Date)? in
                    let key = Self.followUpDeliveryKey(sessionId: session.id, followUpId: followUp.id)
                    guard !inFlightFollowUps.contains(key) else { return nil }
                    if followUp.deliveryPolicy == .autonomousAfterRestart,
                       followUpsHeldForConfirmation.remove(key) != nil {
                        followUpRetryAfter.removeValue(forKey: key)
                    }
                    let retryAt = followUpRetryAfter[key]
                    let dueAt = retryAt.map { Swift.max(followUp.fireAt, $0) } ?? followUp.fireAt
                    return (session.id, followUp, dueAt)
                }
        }
        guard let next = pending.min(by: { $0.2 < $1.2 }) else {
            return
        }
        let delay = max(next.2.timeIntervalSince(now), 0)
        if delay == 0 {
            schedulerLogger.info("Past-due follow-up; firing immediately")
            guard claimFollowUpDelivery(sessionId: next.0, followUpId: next.1.id) else { return }
            Task { await self.fireClaimed(sessionId: next.0, followUpId: next.1.id) }
            return
        }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.claimFollowUpDelivery(sessionId: next.0, followUpId: next.1.id)
                else { return }
                await self.fireClaimed(sessionId: next.0, followUpId: next.1.id)
            }
        }
        source.resume()
        timer = source
        schedulerLogger.info("Next follow-up scheduled \(Int(delay))s from now (session \(next.0.uuidString, privacy: .public))")
    }

    /// Deliver one follow-up into the session's live runtime, then mark the
    /// registry entry as fired. Reschedule runs again automatically via the
    /// registry observer.
    private func fireClaimed(sessionId: UUID, followUpId: UUID) async {
        let deliveryKey = Self.followUpDeliveryKey(sessionId: sessionId, followUpId: followUpId)
        defer {
            inFlightFollowUps.remove(deliveryKey)
        }
        guard let session = registry.session(id: sessionId) else {
            schedulerLogger.warning("fire: session missing — dropping follow-up")
            followUpRetryAfter.removeValue(forKey: deliveryKey)
            followUpsHeldForConfirmation.remove(deliveryKey)
            do {
                try await registry.markFollowUpFired(sessionId: sessionId, followUpId: followUpId)
            } catch {
                schedulerLogger.error("markFollowUpFired write-ahead failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard let followUp = session.scheduledFollowUps.first(where: { $0.id == followUpId }) else {
            followUpRetryAfter.removeValue(forKey: deliveryKey)
            followUpsHeldForConfirmation.remove(deliveryKey)
            return
        }
        guard followUp.deliveryPolicy == .autonomousAfterRestart else {
            followUpsHeldForConfirmation.insert(deliveryKey)
            followUpRetryAfter[deliveryKey] = Date().addingTimeInterval(24 * 60 * 60)
            schedulerLogger.warning("follow-up held for confirmation; not delivering automatically")
            return
        }

        let result: DeliveryResult
        if let deliverer {
            result = await deliverer(session, followUp)
        } else {
            result = await deliverClaudeFollowUp(session: session, followUp: followUp)
        }

        switch result {
        case .delivered:
            followUpRetryAfter.removeValue(forKey: deliveryKey)
            followUpsHeldForConfirmation.remove(deliveryKey)
            do {
                try await registry.markFollowUpFired(sessionId: sessionId, followUpId: followUpId)
            } catch {
                schedulerLogger.error("markFollowUpFired write-ahead failed: \(error.localizedDescription, privacy: .public)")
            }
            schedulerLogger.info("Delivered follow-up to session \(sessionId.uuidString, privacy: .public)")
        case .unavailable(let reason):
            followUpRetryAfter[deliveryKey] = Date().addingTimeInterval(unavailableRetryInterval)
            try? await registry.updateStatus(id: sessionId, status: .degraded)
            schedulerLogger.error("fire: follow-up held pending for \(sessionId.uuidString, privacy: .public): \(reason, privacy: .public)")
        case .retired(let reason):
            followUpRetryAfter.removeValue(forKey: deliveryKey)
            followUpsHeldForConfirmation.remove(deliveryKey)
            do {
                try await registry.removeScheduledFollowUp(sessionId: sessionId, followUpId: followUpId)
            } catch {
                schedulerLogger.error("removeScheduledFollowUp failed: \(error.localizedDescription, privacy: .public)")
            }
            schedulerLogger.error("fire: follow-up retired for \(sessionId.uuidString, privacy: .public): \(reason, privacy: .public)")
        }
    }

    private func deliverClaudeFollowUp(session: AgentSession, followUp: ScheduledFollowUp) async -> DeliveryResult {
        guard session.tmuxPaneId == nil && session.tmuxWindowId == nil else {
            return .retired(reason: "legacy_session_retired")
        }
        guard session.agent == .claude else {
            return .retired(reason: "unsupported_runtime")
        }
        let argv = AgentSpawner.argv(for: session)
        let cwd = session.effectiveCwd
        let host: ClaudePtyHost?
        if !argv.isEmpty {
            // Multi-account: scheduled follow-ups deliver on the session's
            // pinned account. nil env = the account was removed; fall back
            // to a live host only (never respawn under the wrong account).
            if let env = await InstanceSpawnEnv.claudeEnv(for: session) {
                host = try? await ClaudePtyRegistry.shared.resumeOrSpawn(
                    id: session.id,
                    plan: { ClaudePtyRegistry.SpawnPlan(argv: argv, cwd: cwd, env: env) }
                )
            } else {
                host = await ClaudePtyRegistry.shared.host(for: session.id)
            }
        } else {
            host = await ClaudePtyRegistry.shared.host(for: session.id)
        }
        if let host {
            guard await host.submitPrompt(
                followUp.prompt,
                isChat: session.kind == .chat,
                isFollowUp: true,
                origin: followUp.origin
            ) else {
                return .unavailable(reason: "pty_write_failed")
            }
            return .delivered
        } else {
            return .unavailable(reason: "agent_cli_not_found")
        }
    }

    private func claimFollowUpDelivery(sessionId: UUID, followUpId: UUID) -> Bool {
        inFlightFollowUps.insert(Self.followUpDeliveryKey(sessionId: sessionId, followUpId: followUpId)).inserted
    }

    private static func followUpDeliveryKey(sessionId: UUID, followUpId: UUID) -> String {
        "\(sessionId.uuidString):\(followUpId.uuidString)"
    }
}
