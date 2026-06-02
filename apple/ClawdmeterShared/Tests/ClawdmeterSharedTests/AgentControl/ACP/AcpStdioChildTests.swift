#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Verifies the real piped-process primitive end to end with `/bin/cat`
/// (echoes stdin → stdout): write bytes, receive them back, observe exit.
final class AcpStdioChildTests: XCTestCase {

    func testEchoRoundTripAndExit() async throws {
        guard let cat = AcpStdioChild.resolve("cat") else {
            throw XCTSkip("cat not found")
        }
        let child = AcpStdioChild()
        let sink = ByteSink()
        let exited = ExitFlag()
        await child.setOnStdout { await sink.append($0) }
        await child.setOnExit { _ in Task { await exited.set() } }

        try await child.launch(executable: cat, arguments: [], cwd: nil, env: nil)
        try await child.write("hello acp\n".data(using: .utf8)!)

        // poll for the echo (readabilityHandler hops are async)
        var got = ""
        for _ in 0..<50 {
            got = await sink.text
            if got.contains("hello acp") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(got.contains("hello acp"), "cat should echo stdin to stdout; got: \(got)")

        await child.terminate()
        var done = false
        for _ in 0..<50 {
            if await exited.value { done = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(done, "termination handler should fire on exit")
    }

    func testResolveFindsBinaryOnPath() {
        XCTAssertNotNil(AcpStdioChild.resolve("cat"))
        XCTAssertNil(AcpStdioChild.resolve("definitely-not-a-real-binary-xyz"))
    }
}

actor ByteSink {
    private var data = Data()
    func append(_ d: Data) { data.append(d) }
    var text: String { String(data: data, encoding: .utf8) ?? "" }
}
actor ExitFlag {
    private(set) var value = false
    func set() { value = true }
}
#endif
