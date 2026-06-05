import Foundation

/// Track B — B4 / CB-P2a: brute-force protection for the fail-closed peer gate.
///
/// Removing the IP allowlist (B4) makes the pairing-key MAC the only gate, so a
/// LAN attacker can hammer it. This tracks failed auth attempts per source and
/// temporarily bans a source after too many failures in a window — so a daemon
/// that's reachable on a hostile LAN can't be MAC-guessed at line rate. Pure +
/// clock-injectable; the daemon owns one and consults it before verifying.
public final class RelayAuthLockout {

    private struct Strike { var count: Int; var firstAt: Date; var bannedUntil: Date? }

    private let maxFailures: Int
    private let failureWindow: TimeInterval
    private let banDuration: TimeInterval
    private var strikes: [String: Strike] = [:]

    /// - Parameters:
    ///   - maxFailures: failures within `failureWindow` that trigger a ban.
    ///   - failureWindow: rolling window for counting failures.
    ///   - banDuration: how long a source stays locked out once tripped.
    public init(maxFailures: Int = 8, failureWindow: TimeInterval = 60, banDuration: TimeInterval = 300) {
        self.maxFailures = maxFailures
        self.failureWindow = failureWindow
        self.banDuration = banDuration
    }

    /// True if `source` is currently banned (call BEFORE verifying — fail-closed).
    public func isLockedOut(_ source: String, now: Date = Date()) -> Bool {
        guard let s = strikes[source], let until = s.bannedUntil else { return false }
        if now < until { return true }
        // Ban expired — clear it.
        strikes[source] = nil
        return false
    }

    /// Record a failed auth from `source`. Trips a ban at the threshold.
    public func recordFailure(_ source: String, now: Date = Date()) {
        var s = strikes[source] ?? Strike(count: 0, firstAt: now, bannedUntil: nil)
        // Reset the counter if the window has rolled over.
        if now.timeIntervalSince(s.firstAt) > failureWindow {
            s = Strike(count: 0, firstAt: now, bannedUntil: nil)
        }
        s.count += 1
        if s.count >= maxFailures {
            s.bannedUntil = now.addingTimeInterval(banDuration)
        }
        strikes[source] = s
    }

    /// Clear a source's strikes after a successful auth.
    public func recordSuccess(_ source: String) {
        strikes[source] = nil
    }

    /// Drop expired bans/windows (housekeeping).
    public func prune(now: Date = Date()) {
        guard !strikes.isEmpty else { return }
        strikes = strikes.filter { _, s in
            if let until = s.bannedUntil { return now < until }
            return now.timeIntervalSince(s.firstAt) <= failureWindow
        }
    }

    public var trackedSourceCount: Int { strikes.count }
}
