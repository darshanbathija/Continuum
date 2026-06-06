#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Focused source-level regressions for places that still need exact
/// rendering contracts. Broad provider metadata coverage lives in
/// `ProviderDescriptorTests`, which exercises descriptors semantically instead
/// of scanning source text with a fragile allow-list.
final class ProviderHardcodingAuditTests: XCTestCase {

    func test_tahoeUsageViewDoesNotRenderDuplicateGrokBreakdowns() throws {
        let repoRoot = repoRootURL()
        let usageViewURL = repoRoot.appendingPathComponent("apple/ClawdmeterMac/Tahoe/MacUsageView.swift")
        guard FileManager.default.fileExists(atPath: usageViewURL.path) else {
            throw XCTSkip("MacUsageView.swift not present at \(usageViewURL.path)")
        }

        let content = try String(contentsOf: usageViewURL, encoding: .utf8)
        XCTAssertEqual(
            occurrenceCount(of: "ForEach(UsageAnalyticsProvider.order, id: \\.self)", in: content),
            3,
            "Legend, repo bars, and hover breakdown must iterate the canonical provider order."
        )
        XCTAssertEqual(
            occurrenceCount(of: "ForEach(UsageAnalyticsProvider.stackOrder, id: \\.self)", in: content),
            1,
            "SpendChart must stack providers from the canonical provider order."
        )
        XCTAssertEqual(
            occurrenceCount(of: "row(.grok", in: content),
            0,
            "HoverBreakdown must not manually render a Grok row."
        )
        XCTAssertEqual(
            occurrenceCount(of: "Rectangle().fill(grad(.grok))", in: content),
            0,
            "SpendChart and RepoList must not manually render Grok segments."
        )
        XCTAssertTrue(
            content.contains("static var order: [UsageRecord.Provider]") &&
            content.contains("UsageRecord.Provider.analyticsDisplayOrder.filter"),
            "Tahoe usage analytics must source provider order from UsageRecord.Provider.analyticsDisplayOrder."
        )
        XCTAssertTrue(
            content.contains("GrokAnalyticsActivityStrip"),
            "Usage analytics must keep unpriced Grok Build / Composer 2.5 token activity visible in the analytics section."
        )
    }

    func test_grokUsageLimitSurfacesDoNotUseContextWindowData() throws {
        let repoRoot = repoRootURL()
        let popoverURL = repoRoot.appendingPathComponent("apple/ClawdmeterMac/Tahoe/MacMenubarPopover.swift")
        let usageViewURL = repoRoot.appendingPathComponent("apple/ClawdmeterMac/Tahoe/MacUsageView.swift")
        let appDelegateURL = repoRoot.appendingPathComponent("apple/ClawdmeterMac/AppDelegate.swift")
        for url in [popoverURL, usageViewURL, appDelegateURL] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("Required Mac source not present at \(url.path)")
            }
        }

        let popover = try String(contentsOf: popoverURL, encoding: .utf8)
        let usageView = try String(contentsOf: usageViewURL, encoding: .utf8)
        let appDelegate = try String(contentsOf: appDelegateURL, encoding: .utf8)

        XCTAssertTrue(
            popover.contains("label: \"Credits used\""),
            "The Grok popover tab must render the account usage-limit meter, not a context-window meter."
        )
        XCTAssertTrue(
            usageView.contains("case .grok: return \"credits used\""),
            "The Usage tab Grok provider column must label the live gauge as credits usage."
        )
        XCTAssertTrue(
            appDelegate.contains("ProviderStatusController(model: runtime.grokModel"),
            "Grok must use the shared live provider status controller."
        )

        for (name, content) in [
            ("MacMenubarPopover.swift", popover),
            ("MacUsageView.swift", usageView),
            ("AppDelegate.swift", appDelegate),
        ] {
            XCTAssertFalse(
                content.contains("GrokStatusController"),
                "\(name) must not use the old Grok-only context-backed controller."
            )
            XCTAssertFalse(
                content.contains("grokContextLimit"),
                "\(name) must not use Grok context-window data for usage-limit surfaces."
            )
            XCTAssertFalse(
                content.contains("Context window"),
                "\(name) must not label Grok account limits as a context window."
            )
            XCTAssertFalse(
                content.contains("context limit"),
                "\(name) must not describe Grok usage limits as context limits."
            )
        }
    }

    /// Helper — walk up from the test bundle URL to find the repo root
    /// (the directory containing `apple/`).
    private func repoRootURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("apple").path) {
                return url
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory()) // fallback (test will XCTSkip)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
#endif
