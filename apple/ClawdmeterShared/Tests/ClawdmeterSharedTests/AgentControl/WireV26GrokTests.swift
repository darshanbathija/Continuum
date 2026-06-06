import XCTest
@testable import ClawdmeterShared

/// Wire v26 — `AgentKind.grok` + ACP runtime kinds + `ModelCatalog.grok`.
/// Mirrors the WireV24/WireV23 contract-test style. Confirms round-trips,
/// lenient back-compat, the `inferred`/`defaults`/`entries` switches, and the
/// new feature gates.
final class WireV26GrokTests: XCTestCase {

    func testCurrentWireVersion() {
        XCTAssertGreaterThanOrEqual(AgentControlWireVersion.current, 26)
        XCTAssertEqual(AgentControlWireVersion.grokMinimum, 26)
        XCTAssertEqual(AgentControlWireVersion.acpDriveMinimum, 26)
    }

    func testGrokFeatureGates() {
        XCTAssertFalse(AgentControlWireVersion.supportsGrok(serverWireVersion: 25))
        XCTAssertTrue(AgentControlWireVersion.supportsGrok(serverWireVersion: 26))
        XCTAssertFalse(AgentControlWireVersion.supportsGrok(serverWireVersion: nil))
        XCTAssertTrue(AgentControlWireVersion.supportsACPDrive(serverWireVersion: 27))
    }

    func testAgentKindGrokRoundTrip() throws {
        let data = try JSONEncoder().encode(AgentKind.grok)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"grok\"")
        XCTAssertEqual(try JSONDecoder().decode(AgentKind.self, from: data), .grok)
        XCTAssertEqual(AgentKind(rawValue: "grok"), .grok)
    }

    func testOlderRawDecodesToUnknown() throws {
        // A future agent kind a v26 binary doesn't know folds to .unknown
        // (the same forward-compat contract that protects v25 from .grok).
        let d = "\"some_future_agent\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(AgentKind.self, from: d), .unknown)
    }

    func testSessionRuntimeKindAcp() throws {
        XCTAssertEqual(SessionRuntimeKind.acpGrok.rawValue, "acp_grok")
        XCTAssertEqual(SessionRuntimeKind.acpCursor.rawValue, "acp_cursor")
        XCTAssertEqual(SessionRuntimeKind(rawValue: "acp_grok"), .acpGrok)
        let rt = try JSONDecoder().decode(SessionRuntimeKind.self,
                                          from: try JSONEncoder().encode(SessionRuntimeKind.acpGrok))
        XCTAssertEqual(rt, .acpGrok)
    }

    func testInferredAndCapabilities() {
        XCTAssertEqual(SessionRuntimeKind.inferred(agent: .grok), .acpGrok)
        let caps = SessionRuntimeCapabilities.defaults(for: .acpGrok)
        XCTAssertTrue(caps.supportsStreaming)
        XCTAssertTrue(caps.supportsCancel)
        XCTAssertTrue(caps.supportsPermissionPrompts)
        XCTAssertTrue(caps.supportsUsage)
        XCTAssertFalse(caps.supportsTerminal, "fs/terminal off until the Phase 6 trust model")
    }

    /// Phase 5: Cursor is now driven over the native ACP harness, so a freshly
    /// created Cursor session infers `.acpCursor` (not the legacy `.cursorCLI`).
    func testCursorInfersAcpRuntime() {
        XCTAssertEqual(SessionRuntimeKind.inferred(agent: .cursor), .acpCursor)
    }

    func testCodexAndGeminiInferHarnessRuntimes() {
        XCTAssertEqual(SessionRuntimeKind.inferred(agent: .codex), .codexAppServer)
        XCTAssertEqual(SessionRuntimeKind.inferred(agent: .gemini), .agyHeadless)
    }

    /// Old persisted Cursor sessions keep their stored `.cursorCLI` runtime kind
    /// (lenient decode) — the Phase-5 `inferred` flip only affects new spawns.
    func testLegacyCursorCliStillDecodes() throws {
        let rt = try JSONDecoder().decode(SessionRuntimeKind.self,
                                          from: Data("\"cursor_cli\"".utf8))
        XCTAssertEqual(rt, .cursorCLI)
        XCTAssertFalse(rt.isACPDriven)
    }

    /// `isACPDriven` is the daemon's discriminator for routing a session through
    /// the harness bridge vs direct PTY / serve paths.
    func testIsACPDrivenDiscriminator() {
        XCTAssertTrue(SessionRuntimeKind.acpGrok.isACPDriven)
        XCTAssertTrue(SessionRuntimeKind.acpCursor.isACPDriven)
        XCTAssertTrue(SessionRuntimeKind.codexAppServer.isACPDriven)
        XCTAssertTrue(SessionRuntimeKind.agyHeadless.isACPDriven)
        for rt in [SessionRuntimeKind.claudeCLI, .codexCLI, .codexSDK,
                   .opencodeServer, .cursorCLI, .unknown] {
            XCTAssertFalse(rt.isACPDriven, "\(rt.rawValue) must not route to the ACP harness")
        }
    }

    func testModelCatalogGrok() throws {
        XCTAssertFalse(ModelCatalog.bundled.grok.isEmpty)
        XCTAssertEqual(ModelCatalog.bundled.entries(for: .grok).first?.id, "grok-build")
        XCTAssertEqual(ModelCatalog.bundled.byProvider[AgentKind.grok.rawValue]?.first?.id, "grok-build")
        XCTAssertNotNil(ModelCatalog.bundled.entry(forId: "grok-build"))

        // round-trip preserves grok
        let data = try JSONEncoder().encode(ModelCatalog.bundled)
        let decoded = try JSONDecoder().decode(ModelCatalog.self, from: data)
        XCTAssertEqual(decoded.grok.first?.id, "grok-build")
    }

    func testModelCatalogBackCompatMissingGrok() throws {
        // A v25 daemon's catalog JSON lacks `grok` — must decode to [].
        let legacy = """
        {"claude":[],"codex":[],"updatedAt":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModelCatalog.self, from: legacy)
        XCTAssertEqual(decoded.grok, [])
        XCTAssertEqual(decoded.cursor, [])
    }
}
