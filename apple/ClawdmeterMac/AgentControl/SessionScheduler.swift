import Foundation
import ClawdmeterShared
import OSLog

private let schedulerLogger = Logger(subsystem: "com.clawdmeter.mac", category: "SessionScheduler")

/// G15: fires scheduled follow-up prompts at their `fireAt` time by writing
/// into the target session's primary tmux pane via `paste-buffer`.
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

    private let registry: AgentSessionRegistry
    private let tmuxClient: TmuxControlClient

    /// Single re-armable timer. We keep one timer total and adjust its
    /// next-fire deadline whenever follow-ups change — cheaper than one
    /// dispatch source per scheduled item.
    private var timer: DispatchSourceTimer?

    /// Observer token for the registry's @Published change stream.
    private var observerTask: Task<Void, Never>?

    public init(registry: AgentSessionRegistry, tmuxClient: TmuxControlClient) {
        self.registry = registry
        self.tmuxClient = tmuxClient
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
        let pending = registry.sessions.flatMap { session -> [(UUID, ScheduledFollowUp)] in
            session.scheduledFollowUps
                .filter { $0.firedAt == nil }
                .map { (session.id, $0) }
        }
        guard let next = pending.min(by: { $0.1.fireAt < $1.1.fireAt }) else {
            return
        }
        let delay = max(next.1.fireAt.timeIntervalSince(now), 0)
        if delay == 0 {
            schedulerLogger.info("Past-due follow-up; firing immediately")
            Task { await self.fire(sessionId: next.0, followUpId: next.1.id) }
            return
        }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in
            Task { await self?.fire(sessionId: next.0, followUpId: next.1.id) }
        }
        source.resume()
        timer = source
        schedulerLogger.info("Next follow-up scheduled \(Int(delay))s from now (session \(next.0.uuidString, privacy: .public))")
    }

    /// Deliver one follow-up: pastes the prompt + newline into the session's
    /// primary tmux pane, then marks the registry entry as fired. Reschedule
    /// runs again automatically via the registry observer.
    private func fire(sessionId: UUID, followUpId: UUID) async {
        guard let session = registry.session(id: sessionId) else {
            schedulerLogger.warning("fire: session missing — dropping follow-up")
            do {
                try await registry.markFollowUpFired(sessionId: sessionId, followUpId: followUpId)
            } catch {
                schedulerLogger.error("markFollowUpFired write-ahead failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        // Track A: a Claude PTY session has no tmux pane. Deliver to its host,
        // RESUMING/spawning it if it was idle/LRU-suspended (the previous version
        // only delivered to an already-live host, so a swept session silently
        // dropped its follow-up). Resume via the persisted claudeSessionId (T7)
        // baked into AgentSpawner.argv(for:).
        if session.tmuxPaneId == nil && session.tmuxWindowId == nil && session.agent == .claude {
            guard let followUp = session.scheduledFollowUps.first(where: { $0.id == followUpId }) else { return }
            let argv = AgentSpawner.argv(for: session)
            let cwd = session.effectiveCwd
            let host: ClaudePtyHost?
            if !argv.isEmpty {
                let env = AgentSpawner.claudePtyEnv()
                host = try? await ClaudePtyRegistry.shared.resumeOrSpawn(
                    id: sessionId,
                    plan: { ClaudePtyRegistry.SpawnPlan(argv: argv, cwd: cwd, env: env) }
                )
            } else {
                host = await ClaudePtyRegistry.shared.host(for: sessionId)
            }
            if let host {
                await host.submitPrompt(followUp.prompt, isChat: session.kind == .chat, isFollowUp: true)
                do {
                    try await registry.markFollowUpFired(sessionId: sessionId, followUpId: followUpId)
                } catch {
                    schedulerLogger.error("markFollowUpFired write-ahead failed: \(error.localizedDescription, privacy: .public)")
                }
                schedulerLogger.info("Delivered follow-up to PTY session \(sessionId.uuidString, privacy: .public)")
            } else {
                // Could not resume (claude not on PATH). Mark fired to avoid a
                // hot reschedule loop — strictly better than today, which dropped
                // every suspended-session follow-up.
                schedulerLogger.error("fire: could not resume PTY host for \(sessionId.uuidString, privacy: .public); dropping follow-up")
                try? await registry.markFollowUpFired(sessionId: sessionId, followUpId: followUpId)
            }
            return
        }
        guard let pane = session.tmuxPaneId ?? session.tmuxWindowId
        else {
            schedulerLogger.warning("fire: session or pane missing — dropping follow-up")
            // F2-wire: write-ahead failure on the scheduler path is
            // best-effort logged; a failed receipt write still leaves
            // the follow-up in the queue (will retry on next tick).
            do {
                try await registry.markFollowUpFired(sessionId: sessionId, followUpId: followUpId)
            } catch {
                schedulerLogger.error("markFollowUpFired write-ahead failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard let followUp = session.scheduledFollowUps.first(where: { $0.id == followUpId }) else {
            return
        }
        let bytes = Data((followUp.prompt + "\n").utf8)
        do {
            try await tmuxClient.pasteBytes(paneId: pane, bytes: bytes)
            schedulerLogger.info("Delivered follow-up to session \(sessionId.uuidString, privacy: .public)")
        } catch {
            schedulerLogger.error("Failed to paste follow-up: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try await registry.markFollowUpFired(sessionId: sessionId, followUpId: followUpId)
        } catch {
            schedulerLogger.error("markFollowUpFired write-ahead failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
