import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// Tests for v0.8.0's LanguageServerClient rewrite. Phase 0/0.5 proved the
/// real shape of Antigravity 2's language_server (pgrep+ps+lsof discovery,
/// HTTP-RPC via `language_server agentapi <args>`, per-launch CSRF +
/// random ports). These tests cover the pieces we can verify without a
/// live Antigravity.app — the pure parsing, mapping, and discovery
/// orchestration logic.
///
/// Out-of-scope here (covered separately or by integration):
///   - real `pgrep`/`ps`/`lsof` invocation (production-only path)
///   - real `agentapi` subprocess against a running LS (smoke test path)
///   - HTTPS `currentModel()` against gRPC (v0.7 caller, unchanged)
final class LanguageServerClientRewriteTests: XCTestCase {

    // MARK: - parseCSRFToken

    func test_parseCSRFToken_extractsFromSpaceSeparatedFlag() {
        let client = LanguageServerClient(languageServerURL: nil)
        let argv = [
            "/Applications/Antigravity.app/Contents/Resources/bin/language_server",
            "--csrf_token",
            "abc-123-def-456",
            "--https_server_port",
            "0",
        ]
        XCTAssertEqual(client.parseCSRFToken(fromArgv: argv), "abc-123-def-456")
    }

    func test_parseCSRFToken_extractsFromEqualsSeparatedFlag() {
        let client = LanguageServerClient(languageServerURL: nil)
        let argv = [
            "language_server",
            "--csrf_token=99999999-aaaa-bbbb-cccc-dddddddddddd",
        ]
        XCTAssertEqual(
            client.parseCSRFToken(fromArgv: argv),
            "99999999-aaaa-bbbb-cccc-dddddddddddd"
        )
    }

    func test_parseCSRFToken_nilWhenFlagMissing() {
        let client = LanguageServerClient(languageServerURL: nil)
        let argv = ["language_server", "--other_flag", "value"]
        XCTAssertNil(client.parseCSRFToken(fromArgv: argv))
    }

    func test_parseCSRFToken_nilWhenFlagPresentButValueEmpty() {
        let client = LanguageServerClient(languageServerURL: nil)
        let argv = ["language_server", "--csrf_token", ""]
        XCTAssertNil(client.parseCSRFToken(fromArgv: argv))
    }

    func test_parseCSRFToken_nilWhenFlagPresentButLastArg() {
        let client = LanguageServerClient(languageServerURL: nil)
        let argv = ["language_server", "--csrf_token"]
        XCTAssertNil(client.parseCSRFToken(fromArgv: argv))
    }

    // MARK: - AgentapiModelTier.from(modelCatalogId:)

    func test_modelTier_proCatalogIdMapsToPro() {
        XCTAssertEqual(AgentapiModelTier.from(modelCatalogId: "gemini-3.5-pro"), .pro)
        XCTAssertEqual(AgentapiModelTier.from(modelCatalogId: "gemini-3.5-pro-thinking"), .pro)
        XCTAssertEqual(AgentapiModelTier.from(modelCatalogId: "Pro-3"), .pro)
    }

    func test_modelTier_flashLiteCatalogIdMapsToFlashLite() {
        XCTAssertEqual(AgentapiModelTier.from(modelCatalogId: "gemini-3.5-flash_lite"), .flashLite)
        XCTAssertEqual(AgentapiModelTier.from(modelCatalogId: "gemini-3.5-flash-lite"), .flashLite)
    }

    func test_modelTier_flashCatalogIdMapsToFlash() {
        XCTAssertEqual(AgentapiModelTier.from(modelCatalogId: "gemini-3.5-flash"), .flash)
        XCTAssertEqual(AgentapiModelTier.from(modelCatalogId: "gemini-3-flash"), .flash)
        XCTAssertEqual(AgentapiModelTier.from(modelCatalogId: "gemini-3.5-flash-thinking"), .flash)
    }

    func test_modelTier_nilCatalogIdDefaultsToFlash() {
        XCTAssertEqual(AgentapiModelTier.from(modelCatalogId: nil), .flash)
    }

    func test_modelTier_unknownCatalogIdDefaultsToFlash() {
        XCTAssertEqual(AgentapiModelTier.from(modelCatalogId: "some-unknown-model"), .flash)
    }

    func test_modelTier_rawValuesMatchAgentapiContract() {
        // Phase 0 verified agentapi accepts exactly these three strings.
        XCTAssertEqual(AgentapiModelTier.flashLite.rawValue, "flash_lite")
        XCTAssertEqual(AgentapiModelTier.flash.rawValue, "flash")
        XCTAssertEqual(AgentapiModelTier.pro.rawValue, "pro")
    }

    // MARK: - LiveLanguageServer URL synthesis

    func test_liveLanguageServer_httpBaseURL_is127Loopback() {
        let live = LiveLanguageServer(
            pid: 1234,
            csrfToken: "x",
            httpPort: 53824,
            httpsPort: 53823
        )
        XCTAssertEqual(live.httpBaseURL.absoluteString, "http://127.0.0.1:53824")
    }

    func test_liveLanguageServer_httpsBaseURLNilWhenHTTPSPortNil() {
        let live = LiveLanguageServer(pid: 1234, csrfToken: "x", httpPort: 53824, httpsPort: nil)
        XCTAssertNil(live.httpsBaseURL)
    }

    func test_liveLanguageServer_httpsBaseURLWhenHTTPSPortSet() {
        let live = LiveLanguageServer(pid: 1234, csrfToken: "x", httpPort: 53824, httpsPort: 53823)
        XCTAssertEqual(live.httpsBaseURL?.absoluteString, "https://127.0.0.1:53823")
    }

    // MARK: - discoverLive() — ProcessProbe injection

    /// All three probes return success → .live with both ports parsed.
    func test_discoverLive_happyPathReturnsLiveWithBothPorts() {
        let probe = ProcessProbe(
            findAntigravityLSProcessID: { 7777 },
            argvForPID: { _ in ["language_server", "--csrf_token", "TOKEN-XYZ"] },
            listeningTCPPorts: { _ in [53823, 53824] }
        )
        let client = LanguageServerClient(languageServerURL: nil, processProbe: probe)
        guard case let .live(live) = client.discoverLive() else {
            return XCTFail("Expected .live")
        }
        XCTAssertEqual(live.pid, 7777)
        XCTAssertEqual(live.csrfToken, "TOKEN-XYZ")
        // Higher port = HTTP (agentapi), lower = HTTPS (gRPC).
        XCTAssertEqual(live.httpPort, 53824)
        XCTAssertEqual(live.httpsPort, 53823)
    }

    /// Only 1 port — keep httpsPort nil so callers can't construct a
    /// gRPC URL pointing at the HTTP port by accident.
    func test_discoverLive_singlePortYieldsNilHTTPS() {
        let probe = ProcessProbe(
            findAntigravityLSProcessID: { 8888 },
            argvForPID: { _ in ["language_server", "--csrf_token=TOK"] },
            listeningTCPPorts: { _ in [53824] }
        )
        let client = LanguageServerClient(languageServerURL: nil, processProbe: probe)
        guard case let .live(live) = client.discoverLive() else {
            return XCTFail("Expected .live")
        }
        XCTAssertEqual(live.httpPort, 53824)
        XCTAssertNil(live.httpsPort)
    }

    func test_discoverLive_notRunningWhenPgrepReturnsNil() {
        let probe = ProcessProbe(
            findAntigravityLSProcessID: { nil },
            argvForPID: { _ in nil },
            listeningTCPPorts: { _ in [] }
        )
        let client = LanguageServerClient(languageServerURL: nil, processProbe: probe)
        XCTAssertEqual(client.discoverLive(), .notRunning)
    }

    func test_discoverLive_notRunningWhenArgvParseFails() {
        let probe = ProcessProbe(
            findAntigravityLSProcessID: { 1234 },
            argvForPID: { _ in nil },
            listeningTCPPorts: { _ in [53824] }
        )
        let client = LanguageServerClient(languageServerURL: nil, processProbe: probe)
        XCTAssertEqual(client.discoverLive(), .notRunning)
    }

    func test_discoverLive_notRunningWhenCSRFMissingFromArgv() {
        let probe = ProcessProbe(
            findAntigravityLSProcessID: { 1234 },
            argvForPID: { _ in ["language_server", "--other_flag", "value"] },
            listeningTCPPorts: { _ in [53824] }
        )
        let client = LanguageServerClient(languageServerURL: nil, processProbe: probe)
        XCTAssertEqual(client.discoverLive(), .notRunning)
    }

    func test_discoverLive_notRunningWhenNoListeningPorts() {
        let probe = ProcessProbe(
            findAntigravityLSProcessID: { 1234 },
            argvForPID: { _ in ["language_server", "--csrf_token", "TOK"] },
            listeningTCPPorts: { _ in [] }
        )
        let client = LanguageServerClient(languageServerURL: nil, processProbe: probe)
        XCTAssertEqual(client.discoverLive(), .notRunning)
    }

    /// 3+ ports (unusual but documented as possible): largest = HTTP,
    /// smallest = HTTPS, middle ports are ignored. Don't crash.
    func test_discoverLive_multipleListeningPortsPicksExtremes() {
        let probe = ProcessProbe(
            findAntigravityLSProcessID: { 1234 },
            argvForPID: { _ in ["language_server", "--csrf_token", "T"] },
            listeningTCPPorts: { _ in [9000, 9002, 9001] }
        )
        let client = LanguageServerClient(languageServerURL: nil, processProbe: probe)
        guard case let .live(live) = client.discoverLive() else {
            return XCTFail("Expected .live")
        }
        XCTAssertEqual(live.httpPort, 9002)   // sorted last
        XCTAssertEqual(live.httpsPort, 9000)  // sorted first
    }

    // MARK: - LanguageServerProbe equality

    func test_languageServerProbe_notRunningEqualsNotRunning() {
        XCTAssertEqual(LanguageServerProbe.notRunning, .notRunning)
    }

    func test_languageServerProbe_liveEqualsLiveWithSameFields() {
        let a = LiveLanguageServer(pid: 1, csrfToken: "X", httpPort: 100)
        let b = LiveLanguageServer(pid: 1, csrfToken: "X", httpPort: 100)
        XCTAssertEqual(LanguageServerProbe.live(a), .live(b))
    }

    func test_languageServerProbe_liveDifferentPidNotEqual() {
        let a = LiveLanguageServer(pid: 1, csrfToken: "X", httpPort: 100)
        let b = LiveLanguageServer(pid: 2, csrfToken: "X", httpPort: 100)
        XCTAssertNotEqual(LanguageServerProbe.live(a), .live(b))
    }
}
