import XCTest
import SwiftUI
import AppKit
import ClawdmeterShared
@testable import Clawdmeter

/// C2 acceptance gate — measure the body-invalidation drop on a view
/// that reads ONLY a non-snapshot field of `SessionChatStore` (e.g.
/// `pendingMessage`) during a streaming-burst that mutates `snapshot`.
///
/// **What changed in C2:** pre-C2 `SessionChatStore` was
/// `ObservableObject` + `@Published var snapshot`. Every snapshot
/// commit fired `objectWillChange` for the whole store, which
/// invalidated every `@ObservedObject` consumer regardless of which
/// fields they read. The PendingMessageStrip in `ComposerInputCore`
/// only reads `store.pendingMessage` — but with `@ObservedObject` it
/// got dragged through every transcript tick.
///
/// Post-C2 the store is `@Observable`. SwiftUI's
/// `withObservationTracking` registers per-keypath dependencies
/// inside each `body`; a view reading only `pendingMessage` is
/// invalidated only when `pendingMessage` mutates, not when
/// `snapshot` does.
///
/// **Acceptance criterion** (per the C2 row of the plan):
///   ≥30% additional invalidation drop on top of what A5+A9
///   already achieved. A5 slices the snapshot into three
///   `ObservableObject` slices; A9 makes historical rows
///   `Equatable` so SwiftUI skips body on identical payloads. C2
///   removes the remaining cross-field invalidation surface — a
///   view bound to one field of the store no longer feels another
///   field's writes.
///
/// **How we measure:** mount two harnesses side by side.
///   1. `OnlyPendingHarness` reads `store.pendingMessage` only.
///   2. `OnlySnapshotHarness` reads `store.snapshot.updateCounter`
///      only.
///
/// We then drive a burst that mutates ONLY `snapshot` (no
/// pendingMessage changes). Pre-C2: both views would invalidate on
/// every snapshot tick. Post-C2: only the snapshot harness
/// invalidates; the pending harness stays flat.
///
/// We assert directly: pending-harness body invalidations stay near
/// the initial-mount baseline, while snapshot-harness body
/// invalidations scale with the burst. The DROP for the
/// pending-harness (vs the naive baseline of "burst-many
/// invalidations") is the C2 win, and we assert ≥30% improvement
/// over A5/A9's residual cross-field invalidation rate (which was
/// 100% — every snapshot tick re-published the
/// `SessionChatStore.objectWillChange` and dragged in
/// `pendingMessage` observers).
@MainActor
final class SessionChatStoreObservableBurstTests: XCTestCase {
    private var counterLease: UUID?

    /// Token-tick count for the simulated snapshot-burst.
    private let burstTickCount = 100

    override func setUp() async throws {
        try await super.setUp()
        counterLease = await BodyInvalidationCounter.acquireTestLease()
        BodyInvalidationCounter.resetAll()
        BodyInvalidationCounter.enabled = true
    }

    override func tearDown() async throws {
        BodyInvalidationCounter.enabled = false
        BodyInvalidationCounter.resetAll()
        if let counterLease {
            BodyInvalidationCounter.releaseTestLease(counterLease)
            self.counterLease = nil
        }
        try await super.tearDown()
    }

    /// **The C2 acceptance test.** Mount a view that reads ONLY
    /// `store.pendingMessage`, then drive a burst that mutates ONLY
    /// `store.snapshot`. The pending-harness body MUST stay flat —
    /// proves `@Observable` keypath tracking is engaged and that
    /// non-overlapping field reads don't cross-invalidate.
    func test_snapshotBurst_pendingMessageHarness_staysFlat() async throws {
        let store = SessionChatStore(sessionId: UUID(), sdkOnly: true)
        defer { store.stop() }

        // Mount the host. The pending harness reads pendingMessage,
        // the snapshot harness reads snapshot.updateCounter; both
        // bind to the same store.
        let host = NSHostingView(
            rootView: ObservableBurstHarness(store: store)
        )
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        host.layoutSubtreeIfNeeded()
        await flush()

        let pendingBaseline = BodyInvalidationCounter.count(for: "OnlyPendingHarness")
        let snapshotBaseline = BodyInvalidationCounter.count(for: "OnlySnapshotHarness")

        // Drive the burst — N synthetic snapshot mutations. Each
        // tick replaces the entire `snapshot` via the store's
        // package-internal write path (we use a public helper that
        // calls into the staging actor; see `forceSnapshotBump` below).
        for i in 0..<burstTickCount {
            store.forceSnapshotBumpForC2Test(updateCounter: UInt64(i + 1))
            await flush()
        }

        let pendingAfter = BodyInvalidationCounter.count(for: "OnlyPendingHarness")
        let snapshotAfter = BodyInvalidationCounter.count(for: "OnlySnapshotHarness")

        let pendingDelta = pendingAfter - pendingBaseline
        let snapshotDelta = snapshotAfter - snapshotBaseline

        // Diagnostics for the PR body — empirical numbers, not just
        // pass/fail. Mirrors A9's print format.
        print("[C2] BodyInvalidationCounter — snapshot burst:")
        print("[C2]   burst tick count        : \(burstTickCount)")
        print("[C2]   OnlyPendingHarness      : baseline=\(pendingBaseline) after=\(pendingAfter) delta=\(pendingDelta)")
        print("[C2]   OnlySnapshotHarness     : baseline=\(snapshotBaseline) after=\(snapshotAfter) delta=\(snapshotDelta)")
        // Naive baseline: pre-C2 every `objectWillChange` from
        // snapshot writes invalidated every observer (the pending
        // harness included). burstTickCount ticks ⇒ burstTickCount
        // pending-harness body re-evals.
        let naiveBaseline = burstTickCount
        let drop = 1.0 - Double(pendingDelta) / Double(naiveBaseline)
        print("[C2]   cross-field drop        : \(String(format: "%.4f", drop))")

        // C2 invariant: cross-field invalidations must drop ≥30%
        // beyond A5/A9's residual rate. A5/A9 didn't address
        // cross-field reads — pre-C2 any non-snapshot field reader
        // still invalidated on every snapshot tick (the
        // `objectWillChange` fan-out was undiscriminating).
        XCTAssertGreaterThanOrEqual(drop, 0.30,
            "C2 acceptance: cross-field invalidation drop on a snapshot-only burst MUST be ≥30%. Got drop=\(String(format: "%.4f", drop)) (pendingDelta=\(pendingDelta), naive=\(naiveBaseline)).")

        // Snapshot reader DOES invalidate — sanity check we didn't
        // accidentally over-suppress. Without this assertion a
        // mistaken `@ObservationIgnored` on `snapshot` would pass the
        // primary check.
        XCTAssertGreaterThan(snapshotDelta, 0,
            "Sanity: OnlySnapshotHarness.body must actually re-run on snapshot bursts (otherwise the burst plumbing is broken and the primary assertion proves nothing). Got snapshotDelta=\(snapshotDelta).")
    }

    // MARK: - Helpers

    private func flush() async {
        await Task.yield()
        spinMainRunLoop()
    }

    private func spinMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
}

// MARK: - Burst harness

/// Side-by-side harness — `OnlyPendingHarness` reads only
/// `store.pendingMessage`; `OnlySnapshotHarness` reads only
/// `store.snapshot.updateCounter`. Both observe the SAME store. The
/// test drives a burst that only mutates `snapshot`; pre-C2 both
/// bodies would fire (single `objectWillChange` for the whole store),
/// post-C2 only the snapshot-reader body fires.
private struct ObservableBurstHarness: View {
    // Plain stored reference — `@Observable` registers per-keypath
    // dependencies inside each child's body, so the wrapper drops
    // away.
    let store: SessionChatStore

    var body: some View {
        VStack(spacing: 0) {
            OnlyPendingHarness(store: store)
            OnlySnapshotHarness(store: store)
        }
    }
}

/// Reads ONLY `store.pendingMessage`. C2 acceptance: body MUST
/// NOT invalidate when `store.snapshot` mutates.
private struct OnlyPendingHarness: View {
    let store: SessionChatStore

    var body: some View {
        let _ = BodyInvalidationCounter.bump("OnlyPendingHarness")
        Text(store.pendingMessage?.body ?? "(no pending)")
    }
}

/// Reads ONLY `store.snapshot.updateCounter`. Sanity baseline —
/// MUST invalidate when `store.snapshot` mutates.
private struct OnlySnapshotHarness: View {
    let store: SessionChatStore

    var body: some View {
        let _ = BodyInvalidationCounter.bump("OnlySnapshotHarness")
        Text("counter=\(store.snapshot.updateCounter)")
    }
}
