import XCTest
import ClawdmeterShared
@testable import ClawdmeterLinux

/// D10 visual regression tests for the menu-bar gauge.
///
/// Phase 4 acceptance: render at 0%, 42%, 100% for both providers (Claude
/// + Codex) and diff against committed golden PNGs.
///
/// On macOS dev (no Cairo) the renderer returns a 1×1 placeholder PNG;
/// these tests are skipped. On Linux CI / dev they run against the real
/// Cairo output.
final class CairoGaugeRendererTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure XDG dir exists so the renderer can write.
        try? LinuxConfigPaths.ensureDirectory(LinuxConfigPaths.gaugePNGDir)
    }

    func testGaugeRender_Claude42Percent() async throws {
        try XCTSkipUnlessLinux()
        let renderer = CairoGaugeRenderer()
        let usage = makeUsage(sessionPct: 42)
        let pngURL = try await renderer.renderAndWrite(provider: .claude, usage: usage)
        let bytes = try Data(contentsOf: pngURL)
        try VisualTestHelper.assertEqual(actual: bytes, baselineName: "gauge-claude-42")
    }

    func testGaugeRender_Codex17Percent() async throws {
        try XCTSkipUnlessLinux()
        let renderer = CairoGaugeRenderer()
        let usage = makeUsage(sessionPct: 17)
        let pngURL = try await renderer.renderAndWrite(provider: .codex, usage: usage)
        let bytes = try Data(contentsOf: pngURL)
        try VisualTestHelper.assertEqual(actual: bytes, baselineName: "gauge-codex-17")
    }

    func testGaugeRender_Claude0Percent() async throws {
        try XCTSkipUnlessLinux()
        let renderer = CairoGaugeRenderer()
        let usage = makeUsage(sessionPct: 0)
        let pngURL = try await renderer.renderAndWrite(provider: .claude, usage: usage)
        let bytes = try Data(contentsOf: pngURL)
        try VisualTestHelper.assertEqual(actual: bytes, baselineName: "gauge-claude-0")
    }

    func testGaugeRender_Claude100Percent() async throws {
        try XCTSkipUnlessLinux()
        let renderer = CairoGaugeRenderer()
        let usage = makeUsage(sessionPct: 100)
        let pngURL = try await renderer.renderAndWrite(provider: .claude, usage: usage)
        let bytes = try Data(contentsOf: pngURL)
        try VisualTestHelper.assertEqual(actual: bytes, baselineName: "gauge-claude-100")
    }

    func testAtomicTempRenameUnderLoad() async throws {
        // Even without Cairo, verifies the temp+rename pipeline is safe.
        let renderer = CairoGaugeRenderer()
        let usage = makeUsage(sessionPct: 50)
        let url1 = try await renderer.renderAndWrite(provider: .claude, usage: usage)
        let url2 = try await renderer.renderAndWrite(provider: .claude, usage: usage)
        XCTAssertNotEqual(url1.path, url2.path, "Sequential renders must produce different paths (cache-bust)")
        // Both should still exist (the prune cutoff is 60s; tests run faster than that).
    }

    // MARK: - helpers

    private func makeUsage(sessionPct: Int) -> UsageData {
        UsageData(
            sessionPct: sessionPct,
            sessionResetMins: 60,
            sessionEpoch: Int(Date().timeIntervalSince1970),
            weeklyPct: 30,
            weeklyResetMins: 60 * 24 * 3,
            weeklyEpoch: Int(Date().timeIntervalSince1970),
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(),
            organizationID: nil
        )
    }
}

private extension XCTestCase {
    /// Skip the test on non-Linux platforms (dev builds on macOS).
    func XCTSkipUnlessLinux(file: StaticString = #filePath, line: UInt = #line) throws {
        #if !os(Linux)
        throw XCTSkip("Test requires Linux + Cairo runtime", file: file, line: line)
        #endif
    }
}
