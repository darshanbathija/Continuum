#if os(macOS)
import Foundation
import XCTest
@testable import ClawdmeterShared

/// Tests AntigravitySource's 3-tier fallback ladder (D9). Tier 2 logic
/// (the cloudcode-pa retrieveUserQuota path) is exercised by the larger
/// `GeminiProviderLaneATests` suite, which kept its name so the v0.7
/// regression coverage stays intact. This file focuses on:
///
///   - Tier 1 (LS-local probe) being TRIED on every poll
///   - Tier 1 success short-circuits tier 2
///   - Tier 1 returning nil falls through to tier 2 cleanly
///   - Default (probe == nil) behaves identically to v0.7 GeminiSource
final class AntigravitySourceTests: XCTestCase {

    /// Stub token provider — produces a single static token (or nil for
    /// the unauthenticated branch).
    final class StubTokenProvider: TokenProvider, @unchecked Sendable {
        let token: String?
        init(token: String?) { self.token = token }
        var currentAccessToken: String? { token }
        var hasToken: Bool { token != nil }
        func refreshIfNeeded() async throws -> Bool { false }
    }

    final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock(); defer { lock.unlock() }
            value += 1
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private func makeUsageData(pct: Int) -> UsageData {
        let now = Date()
        let epoch = Int(now.timeIntervalSince1970) + 5 * 3600
        return UsageData(
            sessionPct: pct,
            sessionResetMins: 300,
            sessionEpoch: epoch,
            weeklyPct: 0,
            weeklyResetMins: 7 * 24 * 60,
            weeklyEpoch: Int(now.timeIntervalSince1970) + 7 * 24 * 3600,
            status: pct >= 100 ? .limited : .allowed,
            representativeClaim: .fiveHour,
            updatedAt: now
        )
    }

    // MARK: - Tier 1: LS-local probe

    func test_tier1_returnsValueShortCircuitsTier2() async throws {
        let expected = makeUsageData(pct: 47)
        let source = AntigravitySource(
            tokenProvider: StubTokenProvider(token: nil), // tier 2 would throw .unauthenticated
            lsQuotaProbe: { expected }
        )
        let usage = try await source.poll()
        XCTAssertEqual(usage.sessionPct, 47)
        XCTAssertEqual(usage.status, .allowed)
    }

    func test_tier1_nilFallsThroughToTier2() async throws {
        // Tier 1 returns nil → tier 2 needs a token → unauthenticated.
        let source = AntigravitySource(
            tokenProvider: StubTokenProvider(token: nil),
            lsQuotaProbe: { nil }
        )
        do {
            _ = try await source.poll()
            XCTFail("Expected unauthenticated after tier 1 returned nil")
        } catch AISourceError.unauthenticated {
            // ok — tier 2 surface
        }
    }

    func test_tier1_absentFallsThroughToTier2() async throws {
        // No probe = tier 1 disabled. Same as v0.7 GeminiSource path.
        let source = AntigravitySource(
            tokenProvider: StubTokenProvider(token: nil)
        )
        do {
            _ = try await source.poll()
            XCTFail("Expected unauthenticated")
        } catch AISourceError.unauthenticated {
            // ok
        }
    }

    func test_providerIDStaysGeminiForWireBackCompat() {
        let source = AntigravitySource(tokenProvider: StubTokenProvider(token: nil))
        XCTAssertEqual(source.providerID, "gemini",
            "wire providerID must stay 'gemini' in v0.8.0 — iOS/Watch clients on v8/v9 wire decode usage by this key")
    }

    func test_displayNameStaysGeminiInV080() {
        // v0.8.1's cosmetic sweep renames this to "Antigravity"; v0.8.0
        // keeps the label stable so iOS/Mac don't have to ship together.
        let source = AntigravitySource(tokenProvider: StubTokenProvider(token: nil))
        XCTAssertEqual(source.displayName, "Gemini")
    }

    func test_tier1_invokedEvenWhenTokenAvailable() async throws {
        // Token is present — tier 2 would succeed if reached, but tier 1
        // wins regardless. We verify by checking the LS probe runs.
        let probeCallCount = LockedCounter()
        let expected = makeUsageData(pct: 12)
        let source = AntigravitySource(
            tokenProvider: StubTokenProvider(token: "fake-token"),
            lsQuotaProbe: {
                probeCallCount.increment()
                return expected
            }
        )
        _ = try await source.poll()
        XCTAssertEqual(probeCallCount.count, 1, "tier-1 probe must run on every poll (D13: always re-discover)")
    }

    func test_isAuthenticated_reflectsTokenProviderState() {
        let withToken = AntigravitySource(tokenProvider: StubTokenProvider(token: "x"))
        let withoutToken = AntigravitySource(tokenProvider: StubTokenProvider(token: nil))
        XCTAssertTrue(withToken.isAuthenticated)
        XCTAssertFalse(withoutToken.isAuthenticated)
    }
}
#endif
