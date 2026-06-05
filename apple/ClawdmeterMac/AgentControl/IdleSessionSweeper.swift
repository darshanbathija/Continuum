import Foundation
import OSLog
import ClawdmeterShared

private let sweeperLogger = Logger(subsystem: "com.clawdmeter.mac", category: "IdleSessionSweeper")

/// Track A: tear down dormant Claude PTY hosts to bound memory, keeping the
/// session resumable (its `claudeSessionId` + record stay on disk; the next
/// send `resumeOrSpawn`s with `--resume`).
///
/// Two correctness rules the eng review made load-bearing:
/// - **Never mid-turn.** "Idle" is NOT just `lastEventAt` age — a long silent
///   tool call (build, WebFetch, sub-agent) emits nothing to the JSONL for
///   minutes while the turn is still live. Killing then loses in-flight tool
///   state (`--resume` restores the transcript only). So we ALSO require the
///   chat's `currentTurnState != .streaming`.
/// - **Off by default.** Gated on `clawdmeter.claude.idleSuspend.enabled`
///   (default false) until `--resume`-after-rotation is proven on live Claude.
///   The registry's hard-cap LRU-suspend still bounds memory regardless.
///
/// Mirrors `SessionScheduler`'s timer pattern. The suspend DECISION is a pure
/// static fn so it's unit-testable without a process/clock dance.
@MainActor
public final class IdleSessionSweeper {

    private weak var registry: AgentSessionRegistry?
    private weak var chatStoreRegistry: DaemonChatStoreRegistry?
    private let idleSeconds: TimeInterval
    private let tickSeconds: Int
    private let now: () -> Date
    private var timer: DispatchSourceTimer?

    public init(
        registry: AgentSessionRegistry,
        chatStoreRegistry: DaemonChatStoreRegistry,
        idleSeconds: TimeInterval = 300,
        tickSeconds: Int = 30,
        now: @escaping () -> Date = { Date() }
    ) {
        self.registry = registry
        self.chatStoreRegistry = chatStoreRegistry
        self.idleSeconds = idleSeconds
        self.tickSeconds = tickSeconds
        self.now = now
    }

    public var enabled: Bool {
        UserDefaults.standard.bool(forKey: "clawdmeter.claude.idleSuspend.enabled")
    }

    /// Pure suspend decision. A live Claude PTY host is swept only when it's not
    /// mid-turn and has been quiet past the idle window. `nonisolated` so it's
    /// callable (and unit-testable) without the main actor — it touches no state.
    public nonisolated static func shouldSuspend(
        agent: AgentKind,
        hasLiveHost: Bool,
        isStreaming: Bool,
        lastEventAt: Date,
        now: Date,
        idleSeconds: TimeInterval
    ) -> Bool {
        guard agent == .claude, hasLiveHost, !isStreaming else { return false }
        return now.timeIntervalSince(lastEventAt) >= idleSeconds
    }

    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(tickSeconds), repeating: .seconds(tickSeconds))
        t.setEventHandler { [weak self] in Task { await self?.sweep() } }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    func sweep() async {
        guard enabled, let registry, let chatStoreRegistry else { return }
        let current = now()
        for session in registry.sessions where session.agent == .claude {
            let hasHost = await ClaudePtyRegistry.shared.hasLiveHost(session.id)
            guard hasHost else { continue }
            let streaming = chatStoreRegistry.snapshotStore(for: session)?.currentTurnState == .streaming
            if Self.shouldSuspend(
                agent: session.agent,
                hasLiveHost: hasHost,
                isStreaming: streaming,
                lastEventAt: session.lastEventAt,
                now: current,
                idleSeconds: idleSeconds
            ) {
                sweeperLogger.info("idle-suspend session \(session.id.uuidString, privacy: .public)")
                await ClaudePtyRegistry.shared.suspend(session.id)
            }
        }
    }
}
