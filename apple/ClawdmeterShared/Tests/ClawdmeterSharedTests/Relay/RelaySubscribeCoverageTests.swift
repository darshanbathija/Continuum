import XCTest
@testable import ClawdmeterShared

/// Track B — B2: the relay coverage gate. Every daemon WS subscription op must
/// be classified as either relay-reachable or explicitly exempt — so no stream
/// silently lacks a relay path once Tailscale is removed (B5). This test fails
/// if a new WS op is added to `allKnownWSOps` without classifying it.
final class RelaySubscribeCoverageTests: XCTestCase {

    func test_everyKnownWSOp_isRelayedOrExempt() {
        let classified = RelaySubAllowlist.ops.union(RelaySubAllowlist.exemptWSOps)
        let unclassified = RelaySubAllowlist.allKnownWSOps.subtracting(classified)
        XCTAssertTrue(unclassified.isEmpty,
                      "WS ops with no relay path AND not exempt: \(unclassified.sorted()) — classify each.")
    }

    func test_allowlistAndExempt_areDisjoint() {
        let overlap = RelaySubAllowlist.ops.intersection(RelaySubAllowlist.exemptWSOps)
        XCTAssertTrue(overlap.isEmpty, "an op can't be both relayed and exempt: \(overlap.sorted())")
    }

    func test_allowlistAndExempt_areSubsetsOfKnown() {
        XCTAssertTrue(RelaySubAllowlist.ops.isSubset(of: RelaySubAllowlist.allKnownWSOps),
                      "a relayed op must be a known daemon WS op")
        XCTAssertTrue(RelaySubAllowlist.exemptWSOps.isSubset(of: RelaySubAllowlist.allKnownWSOps))
    }

    func test_theFourLiveStreams_plusLifecycle_areRelayed() {
        for op in ["chat-subscribe", "terminal", "events", "frontier-subscribe", "lifecycle-subscribe"] {
            XCTAssertTrue(RelaySubAllowlist.isAllowed(op), "\(op) must be relay-reachable")
        }
        XCTAssertFalse(RelaySubAllowlist.isAllowed("compose-draft"), "compose-draft is a one-shot, not a stream")
    }
}
