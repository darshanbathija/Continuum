import Foundation

/// Single-shot guard: returns true exactly once on the first call,
/// false on every subsequent call. Thread-safe via NSLock.
///
/// v0.7.7 consolidation: replaces the two near-clone NSLock+bool
/// primitives that lived as `ResumeOnce` (ShellRunner.swift) and
/// `BGTaskCompletionGuard` (ClawdmeteriOSApp.swift). Both were
/// solving the same race — one closure that two different callers
/// might enter (terminationHandler vs. timeout in ShellRunner;
/// expirationHandler vs. completing-refresh in iOS BGTask) and
/// only the first caller should fire the side effect.
public final class FireOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    public init() {}

    /// Returns true on the FIRST call, false on every subsequent call.
    /// Thread-safe.
    public func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }

    /// Convenience: run `block` if this is the first fire, no-op
    /// otherwise. Same semantics as guarding `fire()` at the call site
    /// but a touch tidier when the side effect is small.
    public func run(_ block: () -> Void) {
        if fire() { block() }
    }

    /// `true` if `fire()` has already been called. Read-only check;
    /// doesn't claim the slot. Useful for "should I bother computing
    /// the payload" checks before the actual fire.
    public var hasFired: Bool {
        lock.lock(); defer { lock.unlock() }
        return fired
    }
}
