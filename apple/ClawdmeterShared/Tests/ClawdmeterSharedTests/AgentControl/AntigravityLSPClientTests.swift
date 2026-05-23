#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Tests for AntigravityLSPClient. The pure-helper paths (gRPC framing,
/// endpoint construction) run in CI without an Antigravity install.
/// The end-to-end ping test attempts a real call and skips when no LSP
/// is reachable — so CI machines without /Applications/Antigravity.app
/// don't fail.
final class AntigravityLSPClientTests: XCTestCase {

    // MARK: - Pure helpers

    func test_frame_prependsFiveByteHeader() {
        let body = Data([0x01, 0x02, 0x03])
        let framed = AntigravityLSPClient.frame(body: body)
        XCTAssertEqual(framed.count, 5 + 3)
        XCTAssertEqual(framed[0], 0, "uncompressed flag")
        // Bytes 1-4 are the BE length, value=3.
        XCTAssertEqual(framed[1], 0)
        XCTAssertEqual(framed[2], 0)
        XCTAssertEqual(framed[3], 0)
        XCTAssertEqual(framed[4], 3)
        // Payload follows.
        XCTAssertEqual(framed.subdata(in: 5..<8), body)
    }

    func test_frame_emptyBody() {
        let framed = AntigravityLSPClient.frame(body: Data())
        XCTAssertEqual(framed.count, 5, "just the header")
        XCTAssertEqual(Array(framed), [0, 0, 0, 0, 0])
    }

    func test_unframe_stripsHeader() throws {
        let body = Data([0x42, 0x99])
        let framed = AntigravityLSPClient.frame(body: body)
        let roundtripped = try AntigravityLSPClient.unframe(payload: framed)
        XCTAssertEqual(roundtripped, body)
    }

    func test_unframe_rejectsTooShort() {
        XCTAssertThrowsError(try AntigravityLSPClient.unframe(payload: Data([0x00, 0x00]))) { error in
            guard case AntigravityLSPClient.LSPError.invalidResponse = error else {
                XCTFail("expected .invalidResponse, got \(error)")
                return
            }
        }
    }

    func test_endpoint_baseURL() {
        let ep = AntigravityLSPClient.Endpoint(host: "127.0.0.1", port: 54765)
        XCTAssertEqual(ep.baseURL.absoluteString, "https://127.0.0.1:54765")
    }

    // MARK: - Integration (best-effort, skipped if LSP not running)

    /// Attempt to reach a running LSP. Skipped silently when no
    /// instance is found on the host — keeps CI green. Worth running
    /// locally as a smoke test after touching client code.
    func test_pingRealLSP_returnsOK_whenAntigravityIsRunning() async throws {
        guard let endpoint = AntigravityLSPClient.discover() else {
            throw XCTSkip("No language_server process found; skipping live ping")
        }
        let client = AntigravityLSPClient(endpoint: endpoint)
        do {
            _ = try await client.ping()
            // If we get here without throwing, the LSP responded with
            // grpc-status: 0. No payload assertion — HasAuthToken
            // returns a one-field bool whose value depends on whether
            // the user is signed in.
        } catch AntigravityLSPClient.LSPError.transport(let detail) {
            throw XCTSkip("Transport error (probably TLS or no LSP): \(detail)")
        }
    }

    /// Locally-only smoke test: attempt to fetch a real trajectory
    /// from the user's own ~/.gemini/antigravity/conversations/
    /// directory. Skipped on CI / fresh machines. Confirms our
    /// GetCascadeTrajectory request encoding matches what the LSP
    /// expects (this is the only path to real token counts so the
    /// regression cost of breaking it is high).
    func test_getCascadeTrajectory_returnsNonEmptyForRealConversation() async throws {
        guard let endpoint = AntigravityLSPClient.discover() else {
            throw XCTSkip("No language_server process found")
        }
        // Pick a real conversation UUID from disk. Skip if the
        // conversations dir doesn't exist on this machine.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let convDir = home.appendingPathComponent(".gemini/antigravity/conversations")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil),
              let dbFile = entries.first(where: { $0.pathExtension == "db" }) else {
            throw XCTSkip("No .db conversations on this machine")
        }
        let cascadeID = dbFile.deletingPathExtension().lastPathComponent
        let client = AntigravityLSPClient(endpoint: endpoint)
        do {
            let payload = try await client.getCascadeTrajectory(conversationID: cascadeID)
            // We don't parse the response — just confirm it's a real
            // proto blob with content. Trajectories are typically
            // many KB to hundreds of KB.
            XCTAssertGreaterThan(payload.count, 16, "trajectory should be non-trivial")
        } catch AntigravityLSPClient.LSPError.grpcStatus(let code, _) where code == 5 || code == 2 {
            // Code 5 = NotFound, code 2 = Unknown ("trajectory not
            // found"). Acceptable when the cascade isn't live —
            // happens for old archived conversations. Skip rather
            // than fail.
            throw XCTSkip("Trajectory not currently live in the LSP (status code \(code))")
        }
    }

    func test_encodeVarint_smallValues() {
        XCTAssertEqual(AntigravityLSPClient.encodeVarint(0), [0])
        XCTAssertEqual(AntigravityLSPClient.encodeVarint(1), [1])
        XCTAssertEqual(AntigravityLSPClient.encodeVarint(127), [127])
        // 128 needs a continuation byte.
        XCTAssertEqual(AntigravityLSPClient.encodeVarint(128), [0x80, 0x01])
        // 36 (the length of a UUID) — single byte.
        XCTAssertEqual(AntigravityLSPClient.encodeVarint(36), [0x24])
    }

    func test_discover_returnsNilWhenNoLSPRunning() {
        // We can't easily mock lsof, but we can verify the function
        // doesn't crash and returns either nil or a valid Endpoint.
        let result = AntigravityLSPClient.discover()
        if let ep = result {
            XCTAssertGreaterThan(ep.port, 0)
            XCTAssertLessThan(ep.port, 65536)
        }
    }
}
#endif
