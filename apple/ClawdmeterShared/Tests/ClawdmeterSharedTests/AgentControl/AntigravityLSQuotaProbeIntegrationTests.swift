#if os(macOS)
import XCTest
import Compression
@testable import ClawdmeterShared

/// INTEGRATION-only probe — talks to the live Antigravity 2 language_server
/// running on this machine. Skipped by default. Run with:
///   CLAWDMETER_PROBE_LS=1 swift test --filter AntigravityLSQuotaProbeIntegrationTests
///
/// Used during v0.26.6 development to reverse-engineer which gRPC method on
/// `exa.language_server_pb.LanguageServerService` returns the user's quota
/// snapshot. The `.proto` schema isn't published, so we probe by trial:
/// call each candidate method with an empty body, log the raw response bytes,
/// and hand-decode whichever returns quota-shaped data (used_percent doubles +
/// resets_at int64).
final class AntigravityLSQuotaProbeIntegrationTests: XCTestCase {

    /// Gunzip via /usr/bin/gunzip subprocess — simplest robust path
    /// for an integration test. Production probe will use COMPRESSION_RAW
    /// with manual gzip header/trailer stripping.
    static func gunzip(_ data: Data) throws -> Data {
        let tmp = URL(fileURLWithPath: "/tmp/.lsprobe-\(UUID().uuidString).gz")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let task = Process()
        task.launchPath = "/usr/bin/gunzip"
        task.arguments = ["-c", tmp.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try task.run()
        task.waitUntilExit()
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    private var skipUnlessProbeEnabled: Bool {
        ProcessInfo.processInfo.environment["CLAWDMETER_PROBE_LS"] != "1"
    }

    /// Candidate methods to call with empty bodies. Sorted by my prior on
    /// which is most likely to carry usage/quota. Each call logs:
    ///   - grpc-status (0 = OK; method exists and returned data)
    ///   - raw response hex (first 256 bytes)
    ///   - any string substrings that look like percentages or epoch times
    func test_probe_user_info_methods() async throws {
        try XCTSkipIf(skipUnlessProbeEnabled, "Set CLAWDMETER_PROBE_LS=1 to run")

        guard let endpoint = AntigravityLSPClient.discover() else {
            XCTFail("No running language_server discovered — open Antigravity 2 first")
            return
        }
        print("PROBE: discovered language_server at \(endpoint)")
        let client = AntigravityLSPClient(endpoint: endpoint)

        let methods: [String] = [
            "FetchUserInfo",
            "GetLocalUserInfo",
            "GetUserStatus",
            "GetStatus",
            "GetCascadeModelConfigs",
            "GetAvailableModels",
            "GetTokenBase",
            "GetAuthStatusRoundTripper",
        ]

        for method in methods {
            let fullMethod = "/exa.language_server_pb.LanguageServerService/\(method)"
            do {
                let raw = try await client.unary(fullMethod: fullMethod, requestBody: Data())
                // Server compresses responses with gzip even when we request
                // identity. Decompress if magic bytes are present.
                let resp: Data
                if raw.count > 2 && raw[0] == 0x1f && raw[1] == 0x8b {
                    resp = (try? Self.gunzip(raw)) ?? raw
                } else {
                    resp = raw
                }
                print("PROBE \(method): grpc-status=0 OK, raw \(raw.count)B / decoded \(resp.count)B")
                // Uncomment to re-capture fixture bytes for the parser test:
                //   try? resp.write(to: URL(fileURLWithPath: "/tmp/lsprobe-\(method).bin"))
                if let ascii = String(data: resp, encoding: .utf8) {
                    print("    utf8: \(ascii.prefix(800))")
                } else {
                    // Print printable ASCII runs (any 4+-char run of [\x20-\x7e]) — protobuf string fields surface here
                    let chars = Array(resp)
                    var run: [UInt8] = []
                    var runs: [String] = []
                    for b in chars {
                        if b >= 0x20 && b <= 0x7e {
                            run.append(b)
                        } else {
                            if run.count >= 4, let s = String(bytes: run, encoding: .utf8) { runs.append(s) }
                            run = []
                        }
                    }
                    if run.count >= 4, let s = String(bytes: run, encoding: .utf8) { runs.append(s) }
                    print("    strings(>=4): \(runs.prefix(20))")
                }
            } catch let err as AntigravityLSPClient.LSPError {
                print("PROBE \(method): error \(err)")
            } catch {
                print("PROBE \(method): error \(error)")
            }
        }
    }
}
#endif
