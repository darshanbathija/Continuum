import Foundation

/// Thread-safe counter that records how many times a SwiftUI `body`
/// was evaluated. Used by the **A6** invalidation gate (and downstream
/// A8/A9) to assert that splitting a parent view drops the number of
/// body re-evaluations on a sibling sub-tree.
///
/// **Why this exists (the gap A0 left):** A0's `PerfFixtures` provide
/// deterministic data shapes (`sessions500`, `messages10k`, `diff50kLines`)
/// and a `measure { }` template, but XCTest's `measure` reports wall
/// clock — not "how many times did `MyView.body` run". For the A6
/// acceptance criterion (≥50% body-invalidation drop) we need to count
/// the SwiftUI evaluations directly. This counter is the missing piece;
/// it can be wired into any `View.body` via a one-line tap:
///
/// ```swift
/// var body: some View {
///     BodyInvalidationCounter.bump("MyView")
///     return // … real body
/// }
/// ```
///
/// In tests, snapshot the count before + after the state mutation that
/// would have invalidated the parent body, then assert:
///
/// ```swift
/// let before = BodyInvalidationCounter.count(for: "ChatThreadScroll")
/// store.updateSomeIndependentSlice()
/// let after = BodyInvalidationCounter.count(for: "ChatThreadScroll")
/// XCTAssertEqual(after, before, "ChatThreadScroll must not re-render when sidebar state changes")
/// ```
///
/// **Cost:** one atomic dictionary write per body call. Negligible in
/// debug builds; we never enable it in release (see `enabled`).
///
/// **Plan:** A6 (Phase 2) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`. Acceptance
/// per Codex D14#5: invalidation drop, not file length. This utility is
/// how that drop becomes measurable + assertable in CI.
public enum BodyInvalidationCounter {

    /// Toggle off in release. Tests + perf-gate runs set this to `true`;
    /// production app leaves it `false` so the bump is a single boolean
    /// check (zero allocations, zero dictionary touch).
    @MainActor public static var enabled: Bool = false

    /// All counters. Keyed by an opaque label — convention is the view
    /// type name (`"SidebarPane"`, `"ChatThreadScroll"`, …) but any
    /// stable string works.
    @MainActor private static var counts: [String: Int] = [:]

    /// Increment the counter for `label` if `enabled`. Safe to call
    /// from any `View.body` — the call is a no-op when disabled, and
    /// otherwise costs one dictionary write on the main actor (the only
    /// place a SwiftUI body runs).
    ///
    /// Returns `EmptyOptional()` so it composes inline:
    ///
    /// ```swift
    /// var body: some View {
    ///     let _ = BodyInvalidationCounter.bump("Foo")
    ///     return VStack { … }
    /// }
    /// ```
    @MainActor public static func bump(_ label: String) {
        guard enabled else { return }
        counts[label, default: 0] += 1
    }

    /// Current count for `label`. Returns 0 if never bumped.
    @MainActor public static func count(for label: String) -> Int {
        counts[label] ?? 0
    }

    /// Reset every counter. Tests call this in `setUp()` so each test
    /// starts from a known zero baseline.
    @MainActor public static func resetAll() {
        counts.removeAll()
    }

    /// Reset a single counter. Useful when one test wants to measure a
    /// delta in the middle of a longer interaction.
    @MainActor public static func reset(_ label: String) {
        counts.removeValue(forKey: label)
    }

    /// Snapshot every counter — handy for diagnostics when a test
    /// fails and you want to log "here's what got invalidated."
    @MainActor public static func snapshot() -> [String: Int] {
        counts
    }
}
