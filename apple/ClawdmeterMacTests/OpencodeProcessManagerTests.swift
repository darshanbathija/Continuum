import XCTest
@testable import Clawdmeter

/// PR #30 — OpencodeProcessManager unit tests. The full integration
/// (spawning `opencode serve` end-to-end) requires the binary on the
/// test machine; that path is verified manually with `brew install
/// opencode`. These tests cover the pieces we can exercise without
/// the binary:
///   - parseAuthList: lenient parser for `opencode auth list` output
///   - locateBinary: binary discovery with FileManager-backed lookups
///   - State machine initial value + transitions on ensureRunning
///     failure paths (notInstalled branch is reachable without the
///     binary)
@MainActor
final class OpencodeProcessManagerTests: XCTestCase {

    // MARK: - parseAuthList

    func test_parseAuthList_singleProvider() {
        let output = "anthropic: claude-3-5-sonnet"
        let parsed = OpencodeProcessManager.parseAuthList(output)
        XCTAssertEqual(parsed, ["anthropic": "claude-3-5-sonnet"])
    }

    func test_parseAuthList_multipleProviders() {
        let output = """
        anthropic: claude-3-5-sonnet
        openai: gpt-4o
        google: gemini-2.5-pro
        """
        let parsed = OpencodeProcessManager.parseAuthList(output)
        XCTAssertEqual(parsed.count, 3)
        XCTAssertEqual(parsed["anthropic"], "claude-3-5-sonnet")
        XCTAssertEqual(parsed["openai"], "gpt-4o")
        XCTAssertEqual(parsed["google"], "gemini-2.5-pro")
    }

    func test_parseAuthList_skipsBlankLinesAndComments() {
        let output = """

        # available providers
        anthropic: claude-3-5-sonnet

        # signed-out providers below

        openai: gpt-4o
        """
        let parsed = OpencodeProcessManager.parseAuthList(output)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertNil(parsed["#"])  // comment line never parsed
    }

    func test_parseAuthList_skipsDecorativeSeparators() {
        let output = """
        ─────────────
        anthropic: claude-3-5-sonnet
        ─────────────
        """
        let parsed = OpencodeProcessManager.parseAuthList(output)
        XCTAssertEqual(parsed, ["anthropic": "claude-3-5-sonnet"])
    }

    func test_parseAuthList_skipsHeaderLine() {
        // Some CLI variants emit a "Provider: Model" header. The parser
        // explicitly filters lines whose key normalizes to "provider"
        // or "name" so that header doesn't pollute the dict.
        let output = """
        Provider: Model
        anthropic: claude-3-5-sonnet
        """
        let parsed = OpencodeProcessManager.parseAuthList(output)
        XCTAssertEqual(parsed, ["anthropic": "claude-3-5-sonnet"])
        XCTAssertNil(parsed["Provider"])
    }

    func test_parseAuthList_emptyInput() {
        XCTAssertEqual(OpencodeProcessManager.parseAuthList(""), [:])
    }

    func test_parseAuthList_malformedLinesAreIgnored() {
        let output = """
        anthropic: claude-3-5-sonnet
        no-colon-here
        :empty-key
        empty-value:
        codex: gpt-5
        """
        let parsed = OpencodeProcessManager.parseAuthList(output)
        XCTAssertEqual(parsed["anthropic"], "claude-3-5-sonnet")
        XCTAssertEqual(parsed["codex"], "gpt-5")
        XCTAssertEqual(parsed.count, 2)
    }

    func test_parseAuthList_handlesValuesWithColons() {
        // A model id like `claude-3-5-sonnet@v2:beta` should survive
        // the split (maxSplits: 1 means only the first colon is the
        // delimiter).
        let output = "anthropic: claude-3-5-sonnet:beta"
        let parsed = OpencodeProcessManager.parseAuthList(output)
        XCTAssertEqual(parsed["anthropic"], "claude-3-5-sonnet:beta")
    }

    // MARK: - Initial state

    func test_initialState_isStopped() {
        // Note: ProcessManager.shared is a singleton, so this test
        // observes whatever state other tests / app code left it in.
        // We snapshot here to assert it starts stopped after a clean
        // stop() — see test_stop_resetsState below.
        OpencodeProcessManager.shared.stop()
        XCTAssertEqual(OpencodeProcessManager.shared.state, .stopped)
    }

    func test_stop_resetsState() {
        OpencodeProcessManager.shared.stop()
        XCTAssertEqual(OpencodeProcessManager.shared.state, .stopped)
        // Calling stop() twice is safe (idempotent).
        OpencodeProcessManager.shared.stop()
        XCTAssertEqual(OpencodeProcessManager.shared.state, .stopped)
    }

    // MARK: - Binary discovery

    func test_locateBinary_returnsNilWhenNotInstalled() {
        // On a clean CI box with no opencode binary, locateBinary
        // returns nil. Locally with `brew install opencode`, this
        // returns "/opt/homebrew/bin/opencode" — that's still a valid
        // assertion: either nil OR an executable path.
        let path = OpencodeProcessManager.shared.locateBinary()
        if let path {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path),
                "located binary path must point at an executable")
        }
        // Else nil is fine — the binary isn't installed on this host.
    }

    // MARK: - ensureRunning failure path (binary missing)

    func test_ensureRunning_returnsNilWhenBinaryMissing() async throws {
        // If opencode isn't installed on the test host, ensureRunning
        // should yield nil + State.notInstalled. We can only assert
        // this confidently when locateBinary returns nil.
        guard OpencodeProcessManager.shared.locateBinary() == nil else {
            throw XCTSkip("opencode is installed on this host — can't exercise the notInstalled branch")
        }
        OpencodeProcessManager.shared.stop()  // start from clean state
        let port = await OpencodeProcessManager.shared.ensureRunning()
        XCTAssertNil(port)
        XCTAssertEqual(OpencodeProcessManager.shared.state, .notInstalled)
    }
}
