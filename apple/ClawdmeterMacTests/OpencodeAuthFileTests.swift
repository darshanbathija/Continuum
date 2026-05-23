import XCTest
@testable import Clawdmeter

/// v0.23.4 — OpencodeAuthFile tests.
///
/// Each test gets its own isolated temp HOME via `XDG_DATA_HOME`
/// override so we never touch the real `~/.local/share/opencode/auth.json`.
/// The classifier explicitly blocks the agent from reading the real
/// credentials file, and even on the test target we should avoid it —
/// these tests verify schema + atomicity, not the user's actual keys.
@MainActor
final class OpencodeAuthFileTests: XCTestCase {

    private var tempXDGRoot: URL!
    private var savedXDG: String?

    override func setUp() async throws {
        try await super.setUp()
        tempXDGRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clawdmeter-opencode-auth-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempXDGRoot, withIntermediateDirectories: true)
        savedXDG = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        setenv("XDG_DATA_HOME", tempXDGRoot.path, 1)
    }

    override func tearDown() async throws {
        if let savedXDG {
            setenv("XDG_DATA_HOME", savedXDG, 1)
        } else {
            unsetenv("XDG_DATA_HOME")
        }
        try? FileManager.default.removeItem(at: tempXDGRoot)
        try await super.tearDown()
    }

    // MARK: - Schema

    func test_setAPIKey_writesApiTypeEntry() async throws {
        try await OpencodeAuthFile.shared.setAPIKey(
            providerId: "openrouter",
            key: "sk-or-test-12345"
        )
        let entries = await OpencodeAuthFile.shared.readEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries["openrouter"]?["type"] as? String, "api")
        XCTAssertEqual(entries["openrouter"]?["key"] as? String, "sk-or-test-12345")
    }

    func test_setAPIKey_includesMetadataWhenProvided() async throws {
        try await OpencodeAuthFile.shared.setAPIKey(
            providerId: "openrouter",
            key: "sk-test",
            metadata: ["label": "personal", "added": "2026-05-23"]
        )
        let entries = await OpencodeAuthFile.shared.readEntries()
        let metadata = entries["openrouter"]?["metadata"] as? [String: String]
        XCTAssertEqual(metadata?["label"], "personal")
        XCTAssertEqual(metadata?["added"], "2026-05-23")
    }

    func test_setAPIKey_omitsMetadataWhenAbsent() async throws {
        try await OpencodeAuthFile.shared.setAPIKey(providerId: "openrouter", key: "sk-test")
        let entries = await OpencodeAuthFile.shared.readEntries()
        XCTAssertNil(entries["openrouter"]?["metadata"])
    }

    func test_setAPIKey_overwritesExistingEntry() async throws {
        try await OpencodeAuthFile.shared.setAPIKey(providerId: "openrouter", key: "v1")
        try await OpencodeAuthFile.shared.setAPIKey(providerId: "openrouter", key: "v2")
        let entries = await OpencodeAuthFile.shared.readEntries()
        XCTAssertEqual(entries.count, 1, "overwriting must not duplicate the entry")
        XCTAssertEqual(entries["openrouter"]?["key"] as? String, "v2")
    }

    func test_setAPIKey_preservesOtherProviders() async throws {
        try await OpencodeAuthFile.shared.setAPIKey(providerId: "openrouter", key: "sk-or-1")
        try await OpencodeAuthFile.shared.setAPIKey(providerId: "moonshotai", key: "ms-2")
        let ids = await OpencodeAuthFile.shared.providerIds()
        XCTAssertEqual(ids, ["moonshotai", "openrouter"], "providerIds() returns sorted IDs")
    }

    func test_setAPIKey_emptyKeyThrows() async {
        do {
            try await OpencodeAuthFile.shared.setAPIKey(providerId: "openrouter", key: "")
            XCTFail("expected OpencodeAuthError.emptyKey")
        } catch OpencodeAuthError.emptyKey {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_setAPIKey_emptyProviderIdThrows() async {
        do {
            try await OpencodeAuthFile.shared.setAPIKey(providerId: "", key: "sk-test")
            XCTFail("expected OpencodeAuthError.invalidProviderID")
        } catch OpencodeAuthError.invalidProviderID {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_setAPIKey_emptyAfterNormalizationThrows() async {
        // "/" normalizes to "" → must be rejected as invalid.
        do {
            try await OpencodeAuthFile.shared.setAPIKey(providerId: "/", key: "sk-test")
            XCTFail("expected OpencodeAuthError.invalidProviderID")
        } catch OpencodeAuthError.invalidProviderID {
            // ok
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Normalization

    func test_normalize_stripsTrailingSlashes() async {
        let normalized = await OpencodeAuthFile.shared.normalize("openrouter//")
        XCTAssertEqual(normalized, "openrouter")
    }

    func test_normalize_leavesUnchangedWhenNoTrailingSlash() async {
        let normalized = await OpencodeAuthFile.shared.normalize("openrouter")
        XCTAssertEqual(normalized, "openrouter")
    }

    func test_setAPIKey_dropsUnnormalizedDuplicate() async throws {
        // If the caller passes "foo/" (un-normalized), we should remove
        // the "foo/" entry AND write under "foo" so opencode reads it.
        try await OpencodeAuthFile.shared.setAPIKey(providerId: "openrouter/", key: "sk-test")
        let entries = await OpencodeAuthFile.shared.readEntries()
        XCTAssertNotNil(entries["openrouter"], "normalized entry must exist")
        XCTAssertNil(entries["openrouter/"], "un-normalized form must be dropped")
    }

    // MARK: - File mode

    func test_writeEntries_chmod0600() async throws {
        try await OpencodeAuthFile.shared.setAPIKey(providerId: "openrouter", key: "sk-test")
        let attrs = try FileManager.default.attributesOfItem(atPath: OpencodeAuthFile.fileURL.path)
        let perm = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perm?.intValue, 0o600, "auth.json must be chmod 0600")
    }

    func test_writeEntries_directoryCreatedWith0700() async throws {
        try await OpencodeAuthFile.shared.setAPIKey(providerId: "openrouter", key: "sk-test")
        let attrs = try FileManager.default.attributesOfItem(atPath: OpencodeAuthFile.dataDirectoryURL.path)
        let perm = attrs[.posixPermissions] as? NSNumber
        // mkdir intermediates always run with the requested attrs on
        // the final segment; chmod's mode may be lower if umask is
        // restrictive. We accept anything ≤ 0700.
        XCTAssertTrue(
            (perm?.intValue ?? 0) <= 0o700,
            "auth dir must be at most 0o700 (got \(String(perm?.intValue ?? 0, radix: 8)))"
        )
    }

    // MARK: - Remove

    func test_removeProvider_deletesEntry() async throws {
        try await OpencodeAuthFile.shared.setAPIKey(providerId: "openrouter", key: "sk-test")
        try await OpencodeAuthFile.shared.setAPIKey(providerId: "moonshotai", key: "ms-test")
        try await OpencodeAuthFile.shared.removeProvider(providerId: "openrouter")
        let ids = await OpencodeAuthFile.shared.providerIds()
        XCTAssertEqual(ids, ["moonshotai"])
    }

    func test_removeProvider_idempotentWhenMissing() async throws {
        try await OpencodeAuthFile.shared.removeProvider(providerId: "nonexistent")
        // Should not crash + should not create the file.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: OpencodeAuthFile.fileURL.path),
            "removing nonexistent provider must not create the file"
        )
    }

    // MARK: - Read robustness

    func test_readEntries_returnsEmptyWhenFileMissing() async {
        let entries = await OpencodeAuthFile.shared.readEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    func test_readEntries_returnsEmptyOnMalformedJSON() async throws {
        let dir = OpencodeAuthFile.dataDirectoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not valid json".write(
            to: OpencodeAuthFile.fileURL,
            atomically: true,
            encoding: .utf8
        )
        let entries = await OpencodeAuthFile.shared.readEntries()
        XCTAssertTrue(entries.isEmpty, "malformed JSON must surface as empty, not crash")
    }

    /// v0.23.9 P2 regression test: setting a key, then re-reading, must
    /// preserve the entry even when the legacy migration helper runs
    /// (which it does on every read). Earlier code path bailed when
    /// canonical existed AND that fast-path was wrong, but importantly,
    /// the next thing it did was return the canonical bytes — so a
    /// regression where the new merge path corrupts canonical would
    /// show up here as an empty/mismatched read.
    func test_readEntries_preservesEntriesAcrossMigrationProbe() async throws {
        try await OpencodeAuthFile.shared.setAPIKey(providerId: "openrouter", key: "sk-test")
        // Force two reads — migrate runs each time, must not destroy
        // the canonical entry.
        _ = await OpencodeAuthFile.shared.readEntries()
        let entries = await OpencodeAuthFile.shared.readEntries()
        XCTAssertEqual(entries["openrouter"]?["key"] as? String, "sk-test",
                       "canonical entry must survive the legacy-migration probe")
    }
}
