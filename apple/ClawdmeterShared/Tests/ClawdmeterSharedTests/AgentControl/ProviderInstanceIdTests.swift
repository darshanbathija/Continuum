import XCTest
@testable import ClawdmeterShared

/// Tests for F3 `ProviderInstanceId` + `ProviderInstanceRegistry`.
///
/// Locks in:
///   - Primary-instance back-compat: `primary(kind:)` returns a stable
///     synthesized default per kind
///   - `isPrimary` correctly identifies the default
///   - `wireId` is stable and includes kind + name
///   - Codable roundtrip preserves every field
///   - Registry seeds with primaries; upsert + remove + lookup work
///   - Removing a primary is a no-op (back-compat protection)
///   - `instances(for:)` returns primary first, then alphabetical
///
/// Plan: F3 (Phase 1) — see
/// `.claude/plans/study-this-codebase-crystalline-shore.md`
final class ProviderInstanceIdTests: XCTestCase {

    // MARK: - ProviderInstanceId value type

    func test_primary_returnsStableDefault() {
        let a = ProviderInstanceId.primary(kind: .claude)
        let b = ProviderInstanceId.primary(kind: .claude)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.name, ProviderInstanceId.primaryName)
        XCTAssertEqual(a.kind, .claude)
        XCTAssertNil(a.homePathOverride)
        XCTAssertNil(a.keychainAccessGroupOverride)
        XCTAssertTrue(a.isPrimary)
    }

    func test_nonPrimary_isPrimaryReturnsFalse() {
        let custom = ProviderInstanceId(
            kind: .claude,
            name: "personal",
            homePathOverride: "/Users/x/.claude-personal",
            keychainAccessGroupOverride: "com.clawdmeter.kc.personal"
        )
        XCTAssertFalse(custom.isPrimary)
    }

    func test_primaryNameWithOverride_isNotPrimary() {
        // A custom instance can't accidentally claim primary status
        // just by reusing the primary name; the overrides flip the
        // isPrimary check to false.
        let masquerader = ProviderInstanceId(
            kind: .claude,
            name: ProviderInstanceId.primaryName,
            homePathOverride: "/tmp/sneaky"
        )
        XCTAssertFalse(masquerader.isPrimary)
    }

    func test_wireId_includesKindAndName() {
        let p = ProviderInstanceId.primary(kind: .claude)
        XCTAssertEqual(p.wireId, "claude/__primary__")
        let custom = ProviderInstanceId(kind: .codex, name: "pro")
        XCTAssertEqual(custom.wireId, "codex/pro")
    }

    func test_codable_roundTrip() throws {
        let original = ProviderInstanceId(
            kind: .claude,
            name: "work",
            homePathOverride: "/Users/x/.claude-work",
            keychainAccessGroupOverride: "com.clawdmeter.kc.work"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProviderInstanceId.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.homePathOverride, "/Users/x/.claude-work")
        XCTAssertEqual(decoded.keychainAccessGroupOverride, "com.clawdmeter.kc.work")
    }

    func test_hashable_distinguishesInstances() {
        var set = Set<ProviderInstanceId>()
        set.insert(.primary(kind: .claude))
        set.insert(ProviderInstanceId(kind: .claude, name: "personal"))
        set.insert(ProviderInstanceId(kind: .claude, name: "work"))
        XCTAssertEqual(set.count, 3)
    }

    // MARK: - ProviderInstanceRegistry actor

    func test_registry_seedsWithPrimaryForEveryKind() async {
        let reg = ProviderInstanceRegistry()
        for kind in AgentKind.allCases {
            let instancesForKind = await reg.instances(for: kind)
            XCTAssertEqual(instancesForKind.count, 1, "Kind \(kind) should have exactly one primary at init")
            XCTAssertTrue(instancesForKind[0].isPrimary)
        }
    }

    func test_registry_upsertAddsCustomInstance() async {
        let reg = ProviderInstanceRegistry()
        let custom = ProviderInstanceId(
            kind: .claude,
            name: "personal",
            homePathOverride: "/Users/x/.claude-personal"
        )
        await reg.upsert(custom)
        let claudeInstances = await reg.instances(for: .claude)
        XCTAssertEqual(claudeInstances.count, 2)
        XCTAssertTrue(claudeInstances[0].isPrimary, "Primary should sort first")
        XCTAssertEqual(claudeInstances[1].name, "personal")
    }

    func test_registry_upsert_isIdempotent() async {
        let reg = ProviderInstanceRegistry()
        let custom = ProviderInstanceId(kind: .claude, name: "personal")
        await reg.upsert(custom)
        await reg.upsert(custom)
        await reg.upsert(custom)
        let claudeInstances = await reg.instances(for: .claude)
        XCTAssertEqual(claudeInstances.count, 2) // primary + 1 custom
    }

    func test_registry_remove_dropsCustom_butNotPrimary() async {
        let reg = ProviderInstanceRegistry()
        let custom = ProviderInstanceId(kind: .claude, name: "personal")
        await reg.upsert(custom)
        let withCustom = await reg.instances(for: .claude)
        XCTAssertEqual(withCustom.count, 2)

        // Remove custom — works.
        await reg.remove(wireId: custom.wireId)
        let afterRemove = await reg.instances(for: .claude)
        XCTAssertEqual(afterRemove.count, 1)

        // Attempt to remove primary — no-op (back-compat protection).
        let primary = ProviderInstanceId.primary(kind: .claude)
        await reg.remove(wireId: primary.wireId)
        let stillPresent = await reg.instances(for: .claude)
        XCTAssertEqual(stillPresent.count, 1)
        XCTAssertTrue(stillPresent[0].isPrimary)
    }

    func test_registry_lookup_returnsRegistered() async {
        let reg = ProviderInstanceRegistry()
        let custom = ProviderInstanceId(kind: .codex, name: "pro")
        await reg.upsert(custom)
        let looked = await reg.lookup(wireId: custom.wireId)
        XCTAssertEqual(looked, custom)
        let missing = await reg.lookup(wireId: "claude/nonexistent")
        XCTAssertNil(missing)
    }

    func test_registry_instancesFor_returnsPrimaryFirstThenAlphabetical() async {
        let reg = ProviderInstanceRegistry()
        await reg.upsert(ProviderInstanceId(kind: .claude, name: "work"))
        await reg.upsert(ProviderInstanceId(kind: .claude, name: "personal"))
        await reg.upsert(ProviderInstanceId(kind: .claude, name: "agency"))
        let claudeInstances = await reg.instances(for: .claude)
        XCTAssertEqual(claudeInstances.count, 4) // primary + 3 custom
        XCTAssertTrue(claudeInstances[0].isPrimary)
        XCTAssertEqual(claudeInstances[1].name, "agency")
        XCTAssertEqual(claudeInstances[2].name, "personal")
        XCTAssertEqual(claudeInstances[3].name, "work")
    }

    func test_registry_allInstances_returnsEveryRegisteredAcrossKinds() async {
        let reg = ProviderInstanceRegistry()
        await reg.upsert(ProviderInstanceId(kind: .claude, name: "work"))
        await reg.upsert(ProviderInstanceId(kind: .codex, name: "pro"))
        let all = await reg.allInstances()
        // 5 primaries (one per kind) + 2 custom = 7 total.
        XCTAssertEqual(all.count, AgentKind.allCases.count + 2)
    }
}
