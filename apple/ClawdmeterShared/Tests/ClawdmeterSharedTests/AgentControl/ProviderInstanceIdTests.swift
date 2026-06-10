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

    // MARK: - Upsert rejection (P0 back-compat / masquerader protection)

    /// A masquerader (`name == "__primary__"` plus overrides set) MUST NOT
    /// be allowed into the registry — registering it would overwrite the
    /// seeded primary at the same wireId and break every back-compat
    /// caller that asks for `primary(kind:)`.
    func test_registry_upsert_rejectsPrimaryNameMasquerader() async {
        let reg = ProviderInstanceRegistry()
        let masquerader = ProviderInstanceId(
            kind: .claude,
            name: ProviderInstanceId.primaryName,
            homePathOverride: "/tmp/sneaky"
        )
        let result = await reg.upsert(masquerader)
        XCTAssertNil(result, "Masquerader must be rejected by upsert")

        // The seeded primary must still be intact and unchanged.
        let primary = await reg.lookup(wireId: "claude/__primary__")
        XCTAssertNotNil(primary)
        XCTAssertTrue(primary?.isPrimary == true)
        XCTAssertNil(primary?.homePathOverride,
                     "Seeded primary must NOT have been overwritten")
    }

    /// Names containing `/` make the `wireId` (which uses `/` as the
    /// field separator) ambiguous. Reject them so the wire format stays
    /// deterministic.
    func test_registry_upsert_rejectsNameWithSlash() async {
        let reg = ProviderInstanceRegistry()
        let bogus = ProviderInstanceId(kind: .claude, name: "foo/bar")
        let result = await reg.upsert(bogus)
        XCTAssertNil(result, "Name containing '/' must be rejected")
        let lookup = await reg.lookup(wireId: "claude/foo/bar")
        XCTAssertNil(lookup, "Rejected instance must not be in registry")
    }

    /// Empty names produce a wireId like `claude/` — unhelpful and likely
    /// a programming error. Reject.
    func test_registry_upsert_rejectsEmptyName() async {
        let reg = ProviderInstanceRegistry()
        let bogus = ProviderInstanceId(kind: .claude, name: "")
        let result = await reg.upsert(bogus)
        XCTAssertNil(result, "Empty name must be rejected")
    }

    /// The true primary (built via `primary(kind:)`) re-upserts cleanly —
    /// it has no overrides, so the masquerader check doesn't fire.
    func test_registry_upsert_acceptsTruePrimaryReupsert() async {
        let reg = ProviderInstanceRegistry()
        let primary = ProviderInstanceId.primary(kind: .claude)
        let result = await reg.upsert(primary)
        XCTAssertNotNil(result, "True primary must be upsertable (idempotent re-seed)")
        XCTAssertEqual(result, primary)
    }

    // MARK: - Codable forward-compat (P1)

    /// Decoding a JSON payload that carries an extra field (added by a
    /// future writer) must NOT fail — synthesized Codable skips unknown
    /// keys, and we want to lock that contract in.
    func test_codable_decodingExtraField_doesNotFail() throws {
        let json = """
        {
          "kind": "claude",
          "name": "personal",
          "homePathOverride": "/Users/x/.claude-personal",
          "keychainAccessGroupOverride": null,
          "futureField": { "nested": "value" },
          "anotherUnknownKey": 42
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ProviderInstanceId.self, from: json)
        XCTAssertEqual(decoded.kind, .claude)
        XCTAssertEqual(decoded.name, "personal")
        XCTAssertEqual(decoded.homePathOverride, "/Users/x/.claude-personal")
        XCTAssertNil(decoded.keychainAccessGroupOverride)
    }

    // MARK: - Multi-account hardening (path-traversal names + wireId parsing)

    /// Security: the name becomes a path component of the instance config
    /// root, and `removeInstance(deleteConfigRoot:)` recursively deletes
    /// it. Relative-path names ("..", ".") would resolve OUTSIDE
    /// `Instances/<kind>/` and wipe sibling accounts.
    func testIsValidNameRejectsPathTraversalAndUnsafeNames() {
        for bad in ["..", ".", ".hidden", "a/b", "a\\b", "a b", "a\nb", ""] {
            let instance = ProviderInstanceId(kind: .claude, name: bad, homePathOverride: "/tmp/x")
            XCTAssertFalse(instance.isValidName, "name \(bad.debugDescription) must be rejected")
        }
        for good in ["work", "personal", "team-2", "pro_max", "__primary__"] {
            // __primary__ is valid only without overrides (masquerade rule).
            let instance = ProviderInstanceId(kind: .claude, name: good)
            XCTAssertTrue(instance.isValidName, "name \(good.debugDescription) must be accepted")
        }
    }

    func testRegistryRejectsTraversalNames() async {
        let registry = ProviderInstanceRegistry()
        let evil = ProviderInstanceId(kind: .claude, name: "..", homePathOverride: "/tmp/evil")
        let inserted = await registry.upsert(evil)
        XCTAssertNil(inserted)
    }

    func testParseWireId() {
        XCTAssertNil(ProviderInstanceId.parseWireId("claude"))
        XCTAssertNil(ProviderInstanceId.parseWireId("claude/"))
        let parsed = ProviderInstanceId.parseWireId("claude/work")
        XCTAssertEqual(parsed?.kind, "claude")
        XCTAssertEqual(parsed?.name, "work")
        XCTAssertFalse(ProviderInstanceId.isSecondaryWireId("claude"))
        XCTAssertFalse(ProviderInstanceId.isSecondaryWireId("claude/"))
        XCTAssertFalse(ProviderInstanceId.isSecondaryWireId("claude/__primary__"))
        XCTAssertTrue(ProviderInstanceId.isSecondaryWireId("claude/work"))
    }
}
