import XCTest
@testable import ClawdmeterShared

/// Tests for `ClaudeSetupTokenScanner` + `CodexAuthProbe` — the
/// login-completion detectors behind Settings → Add account
/// (multi-account Phase 3).
final class InstanceLoginSupportTests: XCTestCase {

    private let sampleToken = "sk-ant-oat01-" + String(repeating: "Ab3_-", count: 12) // 60-char tail

    // MARK: - Token scanner

    func testFindsTokenInSingleChunk() {
        var scanner = ClaudeSetupTokenScanner()
        let out = scanner.ingest(Data("Your token:\n\(sampleToken)\nStore this safely.".utf8))
        XCTAssertEqual(out, sampleToken)
    }

    func testFindsTokenSplitAcrossChunks() {
        var scanner = ClaudeSetupTokenScanner()
        let full = "token: \(sampleToken)\n"
        let mid = full.index(full.startIndex, offsetBy: full.count / 2)
        XCTAssertNil(scanner.ingest(Data(String(full[..<mid]).utf8)))
        XCTAssertEqual(scanner.ingest(Data(String(full[mid...]).utf8)), sampleToken)
    }

    func testStripsANSIBeforeMatching() {
        var scanner = ClaudeSetupTokenScanner()
        // Token wrapped in color escapes + a cursor-move, with a \r
        // redraw in the middle (spinner overwrite).
        let chunk = "\u{1B}[32m\(sampleToken.prefix(20))\u{1B}[0m\r\u{1B}[32m\(sampleToken)\u{1B}[0m\n"
        XCTAssertEqual(scanner.ingest(Data(chunk.utf8)), sampleToken)
    }

    func testIgnoresBarePrefixInHelpText() {
        var scanner = ClaudeSetupTokenScanner()
        XCTAssertNil(scanner.ingest(Data("tokens look like sk-ant-oat01-XXXX (truncated)".utf8)))
    }

    func testFiresOnceThenResets() {
        var scanner = ClaudeSetupTokenScanner()
        XCTAssertEqual(scanner.ingest(Data(sampleToken.utf8)), sampleToken)
        // The CLI may echo the token again; the scanner must not re-fire
        // off retained buffer alone (a fresh full print does re-match,
        // which is fine — same value).
        XCTAssertNil(scanner.ingest(Data("done.\n".utf8)))
    }

    func testTailBoundDoesNotLoseTokenSpanningBound() {
        var scanner = ClaudeSetupTokenScanner(maxTailBytes: 256)
        // Lots of noise, then a token split across two chunks near the
        // bound — the retained tail must still span it.
        XCTAssertNil(scanner.ingest(Data(String(repeating: "x", count: 1000).utf8)))
        let mid = sampleToken.index(sampleToken.startIndex, offsetBy: 30)
        XCTAssertNil(scanner.ingest(Data(String(sampleToken[..<mid]).utf8)))
        XCTAssertEqual(scanner.ingest(Data(String(sampleToken[mid...]).utf8)), sampleToken)
    }

    // MARK: - Codex auth probe

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstanceLoginSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testProbeFalseWhenMissing() throws {
        XCTAssertFalse(CodexAuthProbe.validAuthExists(configRoot: try tempRoot()))
    }

    func testProbeFalseOnPartialWrite() throws {
        let root = try tempRoot()
        try Data(#"{"auth_mode": "chatgpt", "tokens"#.utf8)
            .write(to: CodexAuthProbe.authFileURL(configRoot: root))
        XCTAssertFalse(CodexAuthProbe.validAuthExists(configRoot: root))
    }

    func testProbeFalseWhenParsedButEmpty() throws {
        let root = try tempRoot()
        try Data(#"{"auth_mode": "chatgpt"}"#.utf8)
            .write(to: CodexAuthProbe.authFileURL(configRoot: root))
        XCTAssertFalse(CodexAuthProbe.validAuthExists(configRoot: root))
    }

    func testProbeTrueWithChatGPTTokens() throws {
        let root = try tempRoot()
        let auth = """
        {"auth_mode": "chatgpt",
         "tokens": {"id_token": "x", "access_token": "tok", "refresh_token": "r", "account_id": "u-1"},
         "last_refresh": "2026-06-11T00:00:00Z"}
        """
        try Data(auth.utf8).write(to: CodexAuthProbe.authFileURL(configRoot: root))
        XCTAssertTrue(CodexAuthProbe.validAuthExists(configRoot: root))
    }

    func testProbeTrueWithAPIKey() throws {
        let root = try tempRoot()
        try Data(#"{"OPENAI_API_KEY": "sk-test"}"#.utf8)
            .write(to: CodexAuthProbe.authFileURL(configRoot: root))
        XCTAssertTrue(CodexAuthProbe.validAuthExists(configRoot: root))
    }

    // MARK: - Account email resolution

    private func makeUnsignedJWT(payloadJSON: String) -> String {
        let payloadB64 = Data(payloadJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "hdr.\(payloadB64).sig"
    }

    func testJWTPayloadReader_decodesBase64URLSegment() throws {
        let jwt = makeUnsignedJWT(payloadJSON: #"{"email":"user@example.com"}"#)
        let payload = try XCTUnwrap(JWTPayloadReader.decodePayloadJSON(jwt))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(json["email"] as? String, "user@example.com")
    }

    func testCodexEmail_fromIdTokenTopLevelClaim() async throws {
        let root = try tempRoot()
        let jwt = makeUnsignedJWT(payloadJSON: #"{"email":"work@company.com"}"#)
        let auth = """
        {"auth_mode": "chatgpt",
         "tokens": {"id_token": "\(jwt)", "access_token": "tok", "refresh_token": "r", "account_id": "u-1"},
         "last_refresh": "2026-06-11T00:00:00Z"}
        """
        try Data(auth.utf8).write(to: CodexAuthProbe.authFileURL(configRoot: root))
        let instance = ProviderInstanceId(kind: .codex, name: "work", homePathOverride: root.path)
        let email = await ProviderAccountEmailResolver.email(for: instance)
        XCTAssertEqual(email, "work@company.com")
    }

    func testCodexEmail_fromProfileClaim() async throws {
        let root = try tempRoot()
        let jwt = makeUnsignedJWT(
            payloadJSON: #"{"https://api.openai.com/profile":{"email":"profile@example.com"}}"#
        )
        let auth = """
        {"auth_mode": "chatgpt",
         "tokens": {"id_token": "\(jwt)", "access_token": "tok", "refresh_token": "r"},
         "last_refresh": "2026-06-11T00:00:00Z"}
        """
        try Data(auth.utf8).write(to: CodexAuthProbe.authFileURL(configRoot: root))
        let instance = ProviderInstanceId(kind: .codex, name: "work", homePathOverride: root.path)
        let email = await ProviderAccountEmailResolver.email(for: instance)
        XCTAssertEqual(email, "profile@example.com")
    }
}
