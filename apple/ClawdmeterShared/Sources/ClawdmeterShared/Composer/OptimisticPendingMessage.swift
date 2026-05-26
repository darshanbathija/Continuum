import Foundation

/// A13 (perf — optimistic composer UI) — value-type state for one
/// optimistically-injected user turn that hasn't yet been confirmed by
/// the daemon. Owned by the Mac-side `SessionChatStore` as a thin slot
/// so the composer surface can render a "Sending…" bubble within 1 frame
/// of the user's send tap (no JSONL round-trip wait).
///
/// State machine: `.sending → (.failed | .queuedOffline | cleared)`.
/// Reconciliation is auto-driven when a matching user-text message lands
/// in the snapshot; `.failed` and `.queuedOffline` are explicit
/// transitions the composer drives in response to daemon responses.
///
/// D24 (eng review) acceptance: when a send is rejected by the daemon
/// the bubble stays visible with an error chip until the user retries
/// or dismisses — it is NOT silently dropped.
///
/// Lives in `ClawdmeterShared` so the value-type behaviour (state machine,
/// equality, codability, accessibility labels) can be unit-tested via
/// the existing `ClawdmeterSharedTests` target. The reconcile logic that
/// inspects the Mac chat snapshot stays on the Mac-side store.
public struct OptimisticPendingMessage: Identifiable, Hashable, Sendable, Codable {

    public enum State: String, Sendable, Hashable, Codable {
        /// In flight — composer is waiting on daemon ack. The pending
        /// bubble renders translucent with a spinner.
        case sending
        /// Daemon rejected the send (4xx / `error` envelope / transport
        /// failure). D24: bubble stays visible, retry chip surfaces.
        case failed
        /// Daemon unreachable — message is staged locally and will
        /// drain on the next successful send. Distinct from `.failed`
        /// so the chip can read "Will send when daemon returns" vs
        /// the explicit-error copy.
        case queuedOffline
    }

    public let id: UUID
    /// Trimmed prose body — matched against the JSONL `user` line's
    /// body for auto-reconcile.
    public let body: String
    /// `@<path>` references for attachments staged alongside the
    /// prompt. Surfaced in the chip so the user knows what's pending.
    public let attachmentRefs: [String]
    public let createdAt: Date
    public let state: State
    /// Human-readable error copy for `.failed` / `.queuedOffline`.
    /// Nil for `.sending`.
    public let errorDescription: String?

    public init(
        id: UUID = UUID(),
        body: String,
        attachmentRefs: [String] = [],
        createdAt: Date = Date(),
        state: State = .sending,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.body = body
        self.attachmentRefs = attachmentRefs
        self.createdAt = createdAt
        self.state = state
        self.errorDescription = errorDescription
    }

    /// Convenience for the composer's UI — true when the bubble should
    /// show a spinner.
    public var isSending: Bool { state == .sending }

    /// True when the user should see a retry affordance.
    public var canRetry: Bool { state == .failed || state == .queuedOffline }

    /// Return a copy with the state machine advanced to `.failed`. The
    /// id + body + attachments + createdAt are preserved so the bubble
    /// doesn't flicker on the state change.
    public func failing(error: String) -> OptimisticPendingMessage {
        OptimisticPendingMessage(
            id: id,
            body: body,
            attachmentRefs: attachmentRefs,
            createdAt: createdAt,
            state: .failed,
            errorDescription: error
        )
    }

    /// Return a copy flipped back to `.sending` — used by the retry
    /// path so the bubble's identity is preserved across the retry
    /// (no flicker out + back in).
    public func retrying() -> OptimisticPendingMessage {
        OptimisticPendingMessage(
            id: id,
            body: body,
            attachmentRefs: attachmentRefs,
            createdAt: createdAt,
            state: .sending,
            errorDescription: nil
        )
    }

    /// Return a copy in the `.queuedOffline` state.
    public func queuedOffline(error: String? = nil) -> OptimisticPendingMessage {
        OptimisticPendingMessage(
            id: id,
            body: body,
            attachmentRefs: attachmentRefs,
            createdAt: createdAt,
            state: .queuedOffline,
            errorDescription: error
        )
    }

    /// Accessibility label for VoiceOver. Distinguishes between in-flight
    /// and rejected sends so screen-reader users hear the same state cue
    /// sighted users see.
    public var accessibilityLabel: String {
        switch state {
        case .sending:        return "Sending message: \(body)"
        case .queuedOffline:  return "Queued offline: \(body)"
        case .failed:         return "Failed to send: \(body). \(errorDescription ?? "")"
        }
    }
}
