// v0.7.7 / T3 from the v0.6.0 eng review: cross-surface ask_user(...)
// race protection. When an Antigravity SDK helper agent (or any future
// sidecar that uses the policy DSL) fires `ask_user(...)`, the prompt
// needs to land on BOTH the Mac inline Plan pane AND the paired iPhone
// via APNS. Two surfaces, one decision — and the user might tap either.
//
// Without this coordinator, two laggy answers could both POST a decision
// back to the daemon, both resume the sidecar's `ask_user`, and the
// second resume would either silently override the first OR throw a
// double-resume trap.
//
// Contract:
//   1. Sidecar registers a prompt: `register(promptUUID:)` returns a
//      Promise that resolves once.
//   2. Mac inline + iOS APNS both POST to `/internal/sidecar-ask/<uuid>/decide`
//      with `{decision, source}`.
//   3. First call: resolves the Promise + records the decision +
//      returns 200. Sidecar's `ask_user` unblocks.
//   4. Subsequent calls: return 409 Conflict with payload
//      `{already_answered, source}`. Losing surface renders "Already
//      answered on iPhone" / "on Mac" and dismisses.
//   5. Timeout: if no surface answers in 60s, default to `deny` and
//      log to AuditLog.

import Foundation
import OSLog
import ClawdmeterShared

private let askLogger = Logger(
    subsystem: "com.clawdmeter.mac",
    category: "SidecarAskCoordinator"
)

public actor SidecarAskCoordinator {

    public static let shared = SidecarAskCoordinator()

    /// Source surface that delivered a decision. Drives the
    /// "Already answered on iPhone" copy on the losing surface.
    public enum Source: String, Sendable, Codable {
        case mac
        case ios
        case timeout
    }

    /// Final decision for a prompt.
    public enum Decision: String, Sendable, Codable {
        case approve
        case deny
    }

    /// Outcome of a `decide` POST. The daemon returns this to the
    /// caller surface so it can render the right UI (success vs. 409
    /// banner vs. timeout marker).
    public enum DecideResult: Sendable, Equatable {
        case won(Decision)
        case lost(prior: Decision, priorSource: Source)
        case unknownPrompt
    }

    /// Internal state for one outstanding prompt.
    private struct PendingPrompt {
        let question: String
        let registeredAt: Date
        var continuation: CheckedContinuation<(Decision, Source), Never>?
        var decided: (Decision, Source)?
    }

    private var pending: [UUID: PendingPrompt] = [:]
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 60.0) {
        self.timeout = timeout
    }

    // MARK: - Sidecar-side API

    /// Register a new ask_user prompt and suspend until either a
    /// surface decides or the timeout fires. Returns the winning
    /// decision + source.
    ///
    /// Call from the sidecar's `pre_tool_call` hook handler.
    public func awaitDecision(promptUUID: UUID, question: String) async -> (Decision, Source) {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<(Decision, Source), Never>) in
            pending[promptUUID] = PendingPrompt(
                question: question,
                registeredAt: Date(),
                continuation: cont,
                decided: nil
            )
            askLogger.info("ask registered uuid=\(promptUUID.uuidString, privacy: .public) question=\(question, privacy: .public)")

            // Arm timeout. If neither surface decides within `timeout`
            // seconds, default to deny.
            let timeoutNs = UInt64(timeout * 1_000_000_000)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNs)
                await self?.fireTimeout(promptUUID: promptUUID)
            }
        }
        return result
    }

    // MARK: - Decision routing (called by daemon routes)

    /// Surface-originated decision. Returns:
    ///   - `.won(decision)` if this caller's decision was the first
    ///   - `.lost(prior, priorSource)` if another surface beat us
    ///   - `.unknownPrompt` if the UUID was never registered or has
    ///     already been GC'd
    @discardableResult
    public func decide(promptUUID: UUID, decision: Decision, source: Source) -> DecideResult {
        guard var prompt = pending[promptUUID] else {
            askLogger.warning("decide on unknown uuid=\(promptUUID.uuidString, privacy: .public)")
            return .unknownPrompt
        }
        if let (priorDecision, priorSource) = prompt.decided {
            askLogger.info("decide lost — uuid=\(promptUUID.uuidString, privacy: .public) prior=\(priorDecision.rawValue) priorSource=\(priorSource.rawValue) lateSource=\(source.rawValue)")
            return .lost(prior: priorDecision, priorSource: priorSource)
        }
        prompt.decided = (decision, source)
        let cont = prompt.continuation
        prompt.continuation = nil
        pending[promptUUID] = prompt
        cont?.resume(returning: (decision, source))
        askLogger.info("decide won — uuid=\(promptUUID.uuidString, privacy: .public) decision=\(decision.rawValue) source=\(source.rawValue)")
        // Best-effort audit log; AuditLog actor handles its own queue.
        Task.detached(priority: .utility) {
            await AuditLog.shared.recordSidecarAsk(
                promptUUID: promptUUID,
                decision: decision.rawValue,
                source: source.rawValue
            )
        }
        // GC the entry after a short delay so a very late POST still
        // returns lost() instead of unknownPrompt — but eventually
        // bounded.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            await self?.gc(promptUUID: promptUUID)
        }
        return .won(decision)
    }

    private func fireTimeout(promptUUID: UUID) {
        guard var prompt = pending[promptUUID] else { return }
        if prompt.decided != nil { return }  // already resolved
        prompt.decided = (.deny, .timeout)
        let cont = prompt.continuation
        prompt.continuation = nil
        pending[promptUUID] = prompt
        cont?.resume(returning: (.deny, .timeout))
        askLogger.warning("ask timed out uuid=\(promptUUID.uuidString, privacy: .public) — defaulting to deny")
        Task.detached(priority: .utility) {
            await AuditLog.shared.recordSidecarAsk(
                promptUUID: promptUUID,
                decision: Decision.deny.rawValue,
                source: Source.timeout.rawValue
            )
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            await self?.gc(promptUUID: promptUUID)
        }
    }

    private func gc(promptUUID: UUID) {
        pending.removeValue(forKey: promptUUID)
    }

    /// Test helper: snapshot of current pending UUIDs. Used by the
    /// xctest UI E2E in `/qa-only` to assert lifecycle.
    public func _testPendingCount() -> Int { pending.count }
}
