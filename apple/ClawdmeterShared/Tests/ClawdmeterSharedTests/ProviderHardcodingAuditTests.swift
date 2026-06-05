#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Regression test for X3-D (Codex eng-review outside-voice). When a new
/// provider lands (Gemini in v6, OpenRouter / Antigravity in v7+), the
/// most common silent bug is leftover binary if-checks like
/// `agent == .claude ? "Claude" : "Codex"` — the falsey branch swallows
/// every non-Claude agent so a Gemini session renders chrome labeled
/// "Codex".
///
/// This test scans the working tree for those literal patterns and asserts
/// each remaining hit is on an allow-list (provider-specific behavior that
/// has been audited and is intentionally fork-style — e.g. plan-mode
/// strings, weekly-limit display logic, AB-pair partner selection where
/// "the other CLI" is genuinely the desired outcome).
///
/// When a hit fires this test, you have three options:
/// 1. Refactor the site through `AgentKindUI` / `displayName(for:)` /
///    `accentRGB(for:)` so all three providers render correctly.
/// 2. If the behavior is genuinely Claude/Codex specific (e.g. weekly
///    cap is Anthropic-only), add the site path to `allowedHits` with a
///    one-line justification in the comment.
/// 3. If the pattern is a false positive (string literal, log message),
///    add the surrounding context to make the regex more specific.
///
/// Per the plan §B in `start-on-a-new-elegant-cascade.md` the goal is
/// "comprehensive audit + regression test" — not "zero hits". Provider-
/// specific behavior is fine; *invisible drift* into provider-specific
/// behavior is what this test catches.
final class ProviderHardcodingAuditTests: XCTestCase {

    /// Each entry is a file path suffix (relative to the repo's `apple/`
    /// dir) where Claude/Codex-specific binary checks are intentional.
    /// Adding to this list requires a justification comment.
    private let allowedFiles: Set<String> = [
        // ProviderConfig — comments only.
        "apple/ClawdmeterMac/ProviderConfig.swift",
        // DashboardView — comments only (D8 referenced by name).
        "apple/ClawdmeterMac/DashboardView.swift",
        // AppModel — Codex-only weekly-poll suppression. Anthropic
        // weekly cap is the only one polled; Codex + Gemini have no
        // weekly window in the wham/usage shape.
        "apple/ClawdmeterMac/AppModel.swift",
        // PopoverView — comments only.
        "apple/ClawdmeterMac/PopoverView.swift",
        // UsageHistoryStore — switch on filter enum is exhaustive,
        // not a binary if-check. The static analyzer sees `provider ==
        // .claude` literals but they live inside `switch self {}` cases.
        "apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/UsageHistoryStore.swift",
        // SessionsV2Theme — pulse-duration falls back to codex value
        // for Gemini (cosmetic, audited 2026-05-19; no chrome
        // mislabel — it's an animation timing).
        "apple/ClawdmeterShared/Sources/ClawdmeterShared/Theme/SessionsV2Theme.swift",
        // WatchTokenBridge — `providerID == "claude"` keeps the legacy
        // single-`usage` field warm for v5 watches reading via the old
        // path. Intentional dual-write.
        "apple/ClawdmeterShared/Sources/ClawdmeterShared/Sources/WatchTokenBridge.swift",
        // LiveCostCalculator — Gemini has no per-request cost data, so
        // it's bucketed into Codex's cost-zero path. Documented in the
        // analytics schema split.
        "apple/ClawdmeterMac/AgentControl/LiveCostCalculator.swift",
        // AttachmentStaging — Codex worktree-mode sandbox path; Gemini
        // doesn't (yet) have a sandbox concept on disk.
        "apple/ClawdmeterMac/Workspace/Composer/AttachmentStaging.swift",
        // SessionActivityStrip (Mac + iOS) — Claude pulse, Codex fade.
        // Gemini doesn't have a thinking-animation contract surfaced
        // yet; falls into the codex branch by design (audited).
        "apple/ClawdmeterMac/Workspace/SessionActivityStrip.swift",
        "apple/ClawdmeteriOS/Components/iOSSessionActivityStrip.swift",
        // iOSSessionsView — AB-pair partner selection is binary (the
        // *other* of Claude/Codex). When Gemini lands in AB-pair
        // selection, this site needs updating.
        "apple/ClawdmeteriOS/iOSSessionsView.swift",
        // ModelPicker (Mac + iOS components) — section header
        // "Claude Code" vs "Codex" routes by switch + we render
        // Gemini in its own section via iOSModelPickerList.
        "apple/ClawdmeterMac/Workspace/ModelPicker.swift",
        "apple/ClawdmeteriOS/Components/iOSModelEffortPill.swift",
        // UsageStatusChip — Mac composer footer; Anthropic-only weekly
        // cap badge. Audited.
        "apple/ClawdmeterMac/Workspace/Composer/UsageStatusChip.swift",
        // ContentView (iOS Live tab) — leading/trailing swipe
        // direction calc is a 2-of-3 fork; Gemini selection forces
        // .leading by design.
        "apple/ClawdmeteriOS/ContentView.swift",
        // SessionsView (Mac) — plan-mode help string is per-agent
        // exhaustive (Claude/Codex/Gemini all enumerated).
        "apple/ClawdmeterMac/SessionsView.swift",
        // AgentControlClient (iOS) — Codex-specific waiting filter.
        "apple/ClawdmeteriOS/AgentControlClient.swift",
        // AgentControlServer (Mac) — argv routing per agent, exhaustive
        // switch internally. Audited.
        "apple/ClawdmeterMac/AgentControl/AgentControlServer.swift",
        // DaemonChatStoreRegistry — Claude JSONL resolution path,
        // Codex/Gemini delegate to SessionFileResolver. Audited.
        "apple/ClawdmeterMac/AgentControl/DaemonChatStoreRegistry.swift",
        // UsageModel (iOS) — Codex-specific `usagePollSuppression` log
        // tag (debug only).
        "apple/ClawdmeteriOS/UsageModel.swift",
        // SessionsListView (Watch) — claude/codex color; gemini falls
        // through to codex blue by design (cosmetic, audited).
        "apple/ClawdmeterWatch/SessionsListView.swift",
    ]

    /// Patterns that, if found outside the allow-list, fail the test.
    /// Kept terse — false positives are caught by the allow-list.
    private let suspiciousPatterns: [String] = [
        "agent == .claude ? \"Claude\" : \"Codex\"",
        "agent == .codex ? \"Codex\" : \"Claude\"",
        "provider == .claude ? \"Claude\" : \"Codex\"",
        "providerID == \"claude\" ? \"Claude\" : \"Codex\"",
        "provider == .claude ? \"ClaudeLogo\" : \"CodexLogo\"",
        "providerID == \"claude\") ? \"ClaudeLogo\" : \"CodexLogo\"",
        ".claude ? \"ClaudeLogo\" : \"CodexLogo\"",
    ]

    func test_noBinaryProviderHardcodingOutsideAllowList() throws {
        let repoRoot = repoRootURL()
        let appleRoot = repoRoot.appendingPathComponent("apple")
        guard FileManager.default.fileExists(atPath: appleRoot.path) else {
            // Running outside the repo (CI clone variant) — skip.
            throw XCTSkip("apple/ not present at \(appleRoot.path)")
        }

        var unjustifiedHits: [(path: String, pattern: String, line: String)] = []
        let enumerator = FileManager.default.enumerator(
            at: appleRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )!

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // Skip test files — they often spell out the patterns for
            // documentation purposes.
            if url.path.contains("/Tests/") { continue }
            // Skip generated bundles.
            if url.path.contains(".build/") || url.path.contains("DerivedData") {
                continue
            }
            // Allow-list match: skip the entire file.
            let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            if allowedFiles.contains(relative) { continue }

            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in content.components(separatedBy: "\n").enumerated() {
                for pattern in suspiciousPatterns {
                    if line.contains(pattern) {
                        unjustifiedHits.append((path: "\(relative):\(i+1)", pattern: pattern, line: line.trimmingCharacters(in: .whitespaces)))
                    }
                }
            }
        }

        if !unjustifiedHits.isEmpty {
            let summary = unjustifiedHits.map { "  \($0.path)  ← matches `\($0.pattern)`\n    \($0.line)" }.joined(separator: "\n")
            XCTFail("""
                Found \(unjustifiedHits.count) hardcoded provider binary check(s) outside the allow-list. \
                When a new provider lands, these branches silently mislabel sessions.
                Either:
                  1. Refactor the site through `AgentKindUI` helpers, or
                  2. Add the file to `allowedFiles` with a comment justifying the provider-specific behavior.

                Hits:
                \(summary)
            """)
        }
    }

    func test_tahoeUsageViewDoesNotRenderDuplicateGrokBreakdowns() throws {
        let repoRoot = repoRootURL()
        let usageViewURL = repoRoot.appendingPathComponent("apple/ClawdmeterMac/Tahoe/MacUsageView.swift")
        guard FileManager.default.fileExists(atPath: usageViewURL.path) else {
            throw XCTSkip("MacUsageView.swift not present at \(usageViewURL.path)")
        }

        let content = try String(contentsOf: usageViewURL, encoding: .utf8)
        XCTAssertEqual(
            occurrenceCount(of: "row(.grok, \"Grok\", point.k)", in: content),
            1,
            "HoverBreakdown must render Grok once."
        )
        XCTAssertEqual(
            occurrenceCount(of: "Rectangle().fill(grad(.grok)).frame(height: d.k / total * h)", in: content),
            1,
            "SpendChart must stack Grok once."
        )
        XCTAssertEqual(
            occurrenceCount(of: "Rectangle().fill(grad(.grok)).frame(width: geo.size.width * width * (r.k / total))", in: content),
            1,
            "RepoList must stack Grok once."
        )
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
