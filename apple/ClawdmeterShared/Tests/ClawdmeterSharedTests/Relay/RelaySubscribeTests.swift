import XCTest
@testable import ClawdmeterShared

/// Track B — B0.2: subscribe spec + the server-side allowlist / envelope.
final class RelaySubscribeTests: XCTestCase {

    func testSpecRoundTrips() throws {
        let spec = RelaySubscribeSpec(op: "chat-subscribe", sessionId: "s1", clientWireVersion: 19)
        let back = try XCTUnwrap(RelaySubscribeSpec.decode(spec.encoded()))
        XCTAssertEqual(back, spec)
    }

    func testAllowlist() {
        XCTAssertTrue(RelaySubAllowlist.isAllowed("chat-subscribe"))
        XCTAssertTrue(RelaySubAllowlist.isAllowed("terminal"))
        XCTAssertTrue(RelaySubAllowlist.isAllowed("events"))
        XCTAssertTrue(RelaySubAllowlist.isAllowed("frontier-subscribe"))
        XCTAssertTrue(RelaySubAllowlist.isAllowed("lifecycle-subscribe"))
        // compose-draft is a one-shot post, NOT a stream — must be excluded.
        XCTAssertFalse(RelaySubAllowlist.isAllowed("compose-draft"))
        XCTAssertFalse(RelaySubAllowlist.isAllowed("GET./sessions"))
        XCTAssertFalse(RelaySubAllowlist.isAllowed("bogus"))
    }

    func testPerChannelPolicy() {
        XCTAssertEqual(RelaySubAllowlist.policy(for: "chat-subscribe"), .snapshotLWW)
        XCTAssertEqual(RelaySubAllowlist.policy(for: "frontier-subscribe"), .snapshotLWW)
        // terminal bytes / events / lifecycle are ordered, never coalesced.
        XCTAssertEqual(RelaySubAllowlist.policy(for: "terminal"), .orderedNoDrop)
        XCTAssertEqual(RelaySubAllowlist.policy(for: "events"), .orderedNoDrop)
        XCTAssertEqual(RelaySubAllowlist.policy(for: "lifecycle-subscribe"), .orderedNoDrop)
    }

    func testLoopbackEnvelopeInjectsServerTokenAndDropsClientFields() throws {
        // Even if the spec somehow carried fields, only the allowlisted data +
        // the SERVER's loopback token may reach the daemon WS envelope.
        let spec = RelaySubscribeSpec(op: "terminal", sessionId: "abc", paneId: "%3")
        let env = try XCTUnwrap(RelaySubAllowlist.loopbackEnvelope(spec: spec, loopbackToken: "SERVER-TOK"))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: env) as? [String: Any])
        XCTAssertEqual(dict["op"] as? String, "terminal")
        XCTAssertEqual(dict["token"] as? String, "SERVER-TOK", "must inject the daemon's own loopback token")
        XCTAssertEqual(dict["sessionId"] as? String, "abc")
        XCTAssertEqual(dict["paneId"] as? String, "%3")
        XCTAssertNil(dict["groupId"], "absent fields must be omitted, not null")
    }

    func testLoopbackEnvelopeRejectsDisallowedOp() {
        let spec = RelaySubscribeSpec(op: "compose-draft", sessionId: "x")
        XCTAssertNil(RelaySubAllowlist.loopbackEnvelope(spec: spec, loopbackToken: "T"))
    }
}
