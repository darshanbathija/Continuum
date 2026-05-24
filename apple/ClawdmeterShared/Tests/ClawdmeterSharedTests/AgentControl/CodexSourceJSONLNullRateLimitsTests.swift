#if os(macOS)
import XCTest
@testable import ClawdmeterShared

/// Regression coverage for the v0.26.1 fix to `CodexSource.parseLatestUsage`.
///
/// Codex CLI 0.132 began emitting an additional `rate_limits` event at
/// session shutdown with `limit_id: "premium"`, `primary: null`,
/// `secondary: null` (a credits-only marker, not a usage update). The
/// previous parser took the textually-last `rate_limits` line in the
/// rollout, which clobbered the real "codex" usage event with this null
/// shutdown marker — the Mac menu-bar gauge dropped to 0% / "resets in —"
/// any time the user closed a codex session.
///
/// The fix: when scanning lines, skip events where `payload.rate_limits
/// .primary` is null or missing, and keep the latest *usable* line.
///
/// Fixtures in this file are minimized real samples captured from
/// `~/.codex/sessions/2026/05/23/rollout-2026-05-23T08-02-08-...jsonl`
/// (the 96%/54% event) and `rollout-2026-05-23T10-21-40-...jsonl` (the
/// premium shutdown marker).
final class CodexSourceJSONLNullRateLimitsTests: XCTestCase {

    // MARK: - Fixtures

    /// A "codex" bucket event with real primary + secondary usage. Trimmed
    /// from a real rollout — only fields the parser reads are retained.
    private static let codexUsageLine = #"""
    {"timestamp":"2026-05-23T03:03:56.045Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"output_tokens":100,"total_tokens":1100},"model_context_window":258400},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":96.0,"window_minutes":300,"resets_at":1779511102},"secondary":{"used_percent":54.0,"window_minutes":10080,"resets_at":1779820784},"credits":null,"plan_type":"prolite","rate_limit_reached_type":null}}}
    """#

    /// The CLI-shutdown marker that broke the parser. `limit_id` flips to
    /// "premium" and primary/secondary are null.
    private static let premiumShutdownLine = #"""
    {"timestamp":"2026-05-23T03:21:49.454Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"premium","limit_name":null,"primary":null,"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":null,"rate_limit_reached_type":null}}}
    """#

    /// Build a JSONL file body from an ordered list of lines.
    private func jsonl(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// A fixed "now" earlier than the codex event's `resets_at`
    /// (1779511102 ≈ 2026-05-23T05:18Z), so the session window is still
    /// considered active and we exercise the .allowed branch rather than
    /// the .notStarted past-reset branch.
    private static let pinnedNow = Date(timeIntervalSince1970: 1779_510_000)

    // MARK: - Tests

    /// The bug, pinned: when the freshest line is the premium shutdown
    /// marker, the parser must IGNORE it and use the prior codex line's
    /// real primary/secondary instead.
    func test_premiumShutdownAfterCodexEvent_usesEarlierCodexUsage() throws {
        let bytes = jsonl([Self.codexUsageLine, Self.premiumShutdownLine])
        let usage = try CodexSource.parseUsageFromJSONLBytes(
            bytes,
            sourceName: "fixture.jsonl",
            now: Self.pinnedNow
        )
        XCTAssertEqual(usage.sessionPct, 96, "Should pick up the codex bucket's 96% primary, not the premium null event")
        XCTAssertEqual(usage.weeklyPct, 54, "Should pick up the codex bucket's 54% secondary")
        XCTAssertEqual(usage.sessionEpoch, 1779511102)
        XCTAssertEqual(usage.weeklyEpoch, 1779820784)
        XCTAssertEqual(usage.status, .allowed, "rate_limit_reached_type is null and resets_at is in the future")
    }

    /// Three events, with a premium shutdown landing in the middle and at
    /// the end. The parser should still surface the codex usage.
    func test_premiumShutdownInterleaved_stillUsesCodexEvent() throws {
        let interleaved = Self.premiumShutdownLine.replacingOccurrences(of: "2026-05-23T03:21:49.454Z", with: "2026-05-23T03:00:00.000Z")
        let bytes = jsonl([interleaved, Self.codexUsageLine, Self.premiumShutdownLine])
        let usage = try CodexSource.parseUsageFromJSONLBytes(
            bytes,
            sourceName: "fixture-interleaved.jsonl",
            now: Self.pinnedNow
        )
        XCTAssertEqual(usage.sessionPct, 96)
        XCTAssertEqual(usage.weeklyPct, 54)
    }

    /// A file containing ONLY shutdown markers (no real usage) should throw
    /// `dataSourceContractViolation` so `poll()` can fall through to an
    /// older rollout. Previously this case decoded as 0%/0%, masking the
    /// fact that no usable data existed.
    func test_onlyPremiumShutdownEvents_throwsContractViolation() {
        let bytes = jsonl([Self.premiumShutdownLine, Self.premiumShutdownLine])
        XCTAssertThrowsError(
            try CodexSource.parseUsageFromJSONLBytes(
                bytes,
                sourceName: "all-null.jsonl",
                now: Self.pinnedNow
            )
        ) { error in
            guard case AISourceError.dataSourceContractViolation(let detail) = error else {
                return XCTFail("Expected dataSourceContractViolation, got \(error)")
            }
            XCTAssertTrue(
                detail.contains("all primary buckets are null") || detail.contains("shutdown markers"),
                "Detail should mention the all-null case — got: \(detail)"
            )
        }
    }

    /// A file with no rate_limits events at all should throw with a
    /// distinct message ("no rate_limits entries yet") so logs can
    /// differentiate "new session, not yet exercised" from "shutdown
    /// markers obscuring real data".
    func test_noRateLimitsAtAll_throwsContractViolationWithDistinctMessage() {
        let unrelated = #"{"timestamp":"2026-05-23T03:00:00.000Z","type":"event_msg","payload":{"type":"user_message","content":"hello"}}"#
        let bytes = jsonl([unrelated])
        XCTAssertThrowsError(
            try CodexSource.parseUsageFromJSONLBytes(
                bytes,
                sourceName: "no-rate-limits.jsonl",
                now: Self.pinnedNow
            )
        ) { error in
            guard case AISourceError.dataSourceContractViolation(let detail) = error else {
                return XCTFail("Expected dataSourceContractViolation, got \(error)")
            }
            XCTAssertTrue(detail.contains("no rate_limits entries yet"), "Distinct detail expected — got: \(detail)")
        }
    }

    /// Sanity check: a single usable codex event still parses correctly
    /// (we didn't break the happy path by adding the null-skip logic).
    func test_singleCodexEvent_parsesCleanly() throws {
        let bytes = jsonl([Self.codexUsageLine])
        let usage = try CodexSource.parseUsageFromJSONLBytes(
            bytes,
            sourceName: "single.jsonl",
            now: Self.pinnedNow
        )
        XCTAssertEqual(usage.sessionPct, 96)
        XCTAssertEqual(usage.weeklyPct, 54)
        XCTAssertEqual(usage.status, .allowed)
    }
}
#endif // os(macOS)
