import XCTest
@testable import ClawdmeterShared

/// E3 #3 regression test. Pre-X3-D, the Mac dashboard + popover used
/// `id == "claude"` to gate the "Keep 5h timer ticking" auto-revive
/// section. When a new provider lands, that hardcoded check would
/// silently slot the new provider into the false branch — Gemini's
/// dashboard column would correctly hide auto-revive, but a future
/// "Claude Pro" or similar would also hide it incorrectly.
///
/// `supportsAutoRevive: Bool` routes through `AutoReviveSupport.supports(_:)`
/// — a single source of truth in shared. This test locks the current contract:
///
///   - "claude" → false (prompt-based keepalives create throwaway
///     conversations and consume quota).
///   - "codex"  → false (wham/usage quota is activity-tied; ping doesn't
///     extend it).
///   - "gemini" → false (cloudcode-pa is 24h-style refreshes per model;
///     no benefit).
///   - Unknown providers default false (defensive — future providers must
///     opt in via this lookup explicitly, not via a hardcoded check at
///     some other site).
final class ProviderConfigAutoReviveTests: XCTestCase {

    func test_claudeDoesNotSupportAutoRevive() {
        XCTAssertFalse(AutoReviveSupport.supports("claude"))
    }

    func test_codexDoesNotSupportAutoRevive() {
        XCTAssertFalse(AutoReviveSupport.supports("codex"))
    }

    func test_geminiDoesNotSupportAutoRevive() {
        XCTAssertFalse(AutoReviveSupport.supports("gemini"))
    }

    func test_unknownProviderDefaultsFalse() {
        XCTAssertFalse(AutoReviveSupport.supports("mistral"))
        XCTAssertFalse(AutoReviveSupport.supports(""))
        XCTAssertFalse(AutoReviveSupport.supports("openrouter"),
                       "Future providers must opt in via AutoReviveSupport.supports, not via a hardcoded check elsewhere")
    }
}
