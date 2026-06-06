import Foundation
import OSLog

private let supervisorLogger = Logger(subsystem: "com.clawdmeter.mac", category: "TmuxSupervisor")

/// Watchdog for `TmuxControlClient`. Consumes the client's lifecycle
/// AsyncStream, auto-restarts on `%exit` with bounded backoff, and updates
/// the `AgentSessionRegistry` to mark sessions as `degraded` so the UI
/// can surface a "tmux server lost — recover" banner.
///
/// Per Codex eng-round High #4 + T23:
/// - tmux dies for any reason → mark every live session `.degraded` (not
///   deleted). The registry retains them; the UI shows a degraded badge.
/// - Attempt up to 3 restarts with exponential backoff (1s, 3s, 9s). After
///   that, give up and surface "tmux unrecoverable" — user can manually
///   relaunch the daemon.
/// - On successful restart: emit `tmuxServerRecovered` (Phase 4 WS event)
///   so iOS clients refresh; sessions stay degraded until the user
///   explicitly restarts them (we can't blindly re-spawn agents — they
///   may have side effects).
@MainActor
public final class TmuxSupervisor {

    private let tmux: TmuxControlClient
    private let registry: AgentSessionRegistry

    private var watchTask: Task<Void, Never>?
    private var restartAttempts: Int = 0
    private let maxRestartAttempts = 3

    /// Set when supervisor detects an unrecoverable tmux state. UI binds
    /// to this via Combine in the SessionsModel to render the banner.
    @Published public private(set) var isRecoveryBlocked: Bool = false

    /// Counter that increments on each successful restart. Mostly a debug
    /// counter, but consumers can observe it to know "tmux restarted".
    @Published public private(set) var restartCount: Int = 0

    public init(tmux: TmuxControlClient, registry: AgentSessionRegistry) {
        self.tmux = tmux
        self.registry = registry
    }

    /// Begin watching the tmux client's lifecycle stream. Idempotent.
    public func start() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            await self?.watchLoop()
        }
    }

    public func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    private func watchLoop() async {
        // Initial start.
        do {
            try await tmux.start()
            supervisorLogger.info("Initial tmux start succeeded")
        } catch {
            supervisorLogger.error("Initial tmux start failed: \(error.localizedDescription)")
        }

        while !Task.isCancelled {
            guard let stream = await tmux.lifecycleStream else {
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            var handledServerExitInStream = false
            for await event in stream {
                if Task.isCancelled { return }
                switch event {
                case .ready:
                    restartAttempts = 0  // healthy run resets the counter
                    isRecoveryBlocked = false
                case .windowAdded, .windowClosed:
                    break  // Phase 4 wires these to registry sync
                case .serverExited(let reason):
                    supervisorLogger.warning("tmux server exited: \(reason ?? "unknown") — marking sessions degraded")
                    handledServerExitInStream = true
                    await markAllSessionsDegraded()
                    await attemptRestart()
                }
            }
            // Stream finished without us cancelling — try to restart.
            if !Task.isCancelled && !handledServerExitInStream {
                await attemptRestart()
            }
        }
    }

    private func markAllSessionsDegraded() async {
        for session in registry.sessions where session.status != .degraded {
            // F2-wire: write-ahead failures on the supervisor path are
            // best-effort logged. We can't usefully fail the supervisor
            // loop (the tmux server is already gone — the right answer
            // is "mark degraded if we can"). Logging keeps the receipt
            // breach visible without crashing recovery.
            do {
                try await registry.updateStatus(id: session.id, status: .degraded)
            } catch {
                supervisorLogger.error("updateStatus(.degraded) write-ahead failed for \(session.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func attemptRestart() async {
        if restartAttempts >= maxRestartAttempts {
            supervisorLogger.error("tmux restart attempts exhausted (\(self.maxRestartAttempts)); manual recovery required")
            isRecoveryBlocked = true
            return
        }
        restartAttempts += 1
        let delaySeconds = pow(3.0, Double(restartAttempts - 1))  // 1, 3, 9
        supervisorLogger.info("Restart attempt \(self.restartAttempts) in \(delaySeconds)s")
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        if Task.isCancelled { return }
        do {
            try await tmux.start()
            restartCount += 1
            isRecoveryBlocked = false
            supervisorLogger.info("tmux restart succeeded (count=\(self.restartCount))")
        } catch {
            supervisorLogger.error("tmux restart \(self.restartAttempts) failed: \(error.localizedDescription)")
        }
    }

    /// User-initiated manual recovery (e.g. "Recover" button in the banner).
    /// Resets the attempt counter and tries again.
    public func userInitiatedRecovery() async {
        restartAttempts = 0
        isRecoveryBlocked = false
        await attemptRestart()
    }
}
