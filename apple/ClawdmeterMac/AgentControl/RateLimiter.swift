import Foundation

/// Per-session rate limits for mid-session daemon operations. Sessions v2 T12.
///
/// Bounds:
/// - send-prompt: 1 message / second per session
/// - model/effort/mode swap: 1 swap / 5 seconds per session
///
/// These are defense-in-depth against a misbehaving (or compromised)
/// iOS client. Real iOS users don't hit these in normal use.
@MainActor
public final class RateLimiter {
    public static let shared = RateLimiter()

    private var lastSendAt: [UUID: Date] = [:]
    private var lastSwapAt: [UUID: Date] = [:]

    private static let sendInterval: TimeInterval = 1.0
    private static let swapInterval: TimeInterval = 5.0

    public init() {}

    /// Returns true when the send is allowed. Records the timestamp on
    /// success. Caller responds 429 on false.
    public func tryAcquireSend(sessionId: UUID) -> Bool {
        let now = Date()
        if let last = lastSendAt[sessionId], now.timeIntervalSince(last) < Self.sendInterval {
            return false
        }
        lastSendAt[sessionId] = now
        return true
    }

    public func tryAcquireSwap(sessionId: UUID) -> Bool {
        let now = Date()
        if let last = lastSwapAt[sessionId], now.timeIntervalSince(last) < Self.swapInterval {
            return false
        }
        lastSwapAt[sessionId] = now
        return true
    }

    public func releaseSession(_ sessionId: UUID) {
        lastSendAt.removeValue(forKey: sessionId)
        lastSwapAt.removeValue(forKey: sessionId)
    }
}
