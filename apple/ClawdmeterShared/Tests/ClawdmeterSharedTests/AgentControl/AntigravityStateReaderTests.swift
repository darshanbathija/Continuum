import XCTest
@testable import ClawdmeterShared

/// Exercises `AntigravityStateReader.parse` against real fixtures captured
/// from a live Antigravity 2.0.0 install, plus malformed-input edge cases.
final class AntigravityStateReaderTests: XCTestCase {

    /// Real text-proto from `~/.gemini/antigravity/antigravity_state.pbtxt`
    /// on a v2.0.0 install (captured 2026-05-20). Drives the happy-path
    /// regression assertion.
    private let liveFixture: String = """
    post_onboarding:  {
      completed_steps:  POST_ONBOARDING_STEP_TYPE_MANAGER_WELCOME
      completed_steps:  POST_ONBOARDING_STEP_TYPE_USAGE_MODE
      completed_steps:  POST_ONBOARDING_STEP_TYPE_AGENT_CONFIGURATION
      completed_steps:  POST_ONBOARDING_STEP_TYPE_ADD_WORKSPACE
    }
    seen_nuxs:  {
      uids:  23
    }
    agent_onboarding_completed:  AGENT_ONBOARDING_STATE_COMPLETED
    last_selected_agent_model:  MODEL_PLACEHOLDER_M133
    migrate_convos_into_projects:  MIGRATION_STATUS_COMPLETED
    installation_uuid:  "fd6a5ba1-7a30-425a-aba1-4f0cdc5b1361"
    """

    func test_parse_liveFixture_extractsAllThreeScalars() {
        let state = AntigravityStateReader.parse(text: liveFixture)
        XCTAssertEqual(state.lastSelectedAgentModelToken, "MODEL_PLACEHOLDER_M133")
        XCTAssertEqual(state.installationUUID, "fd6a5ba1-7a30-425a-aba1-4f0cdc5b1361")
        XCTAssertEqual(state.migrationStatus, .completed)
    }

    func test_parse_resolvesM133ToGemini35Flash() {
        let state = AntigravityStateReader.parse(text: liveFixture)
        XCTAssertEqual(state.displayModelName, "gemini-3.5-flash")
    }

    // v0.23.8: pin the new I/O-2026 placeholder mapping. Before this
    // commit, a session on M134 (Gemini 3.1 Pro) priced at $0 because
    // the raw placeholder string fell through `Pricing.shared.cost(...)`.
    func test_parse_resolvesM134ToGemini31Pro() {
        let text = "last_selected_agent_model:  MODEL_PLACEHOLDER_M134"
        let state = AntigravityStateReader.parse(text: text)
        XCTAssertEqual(state.displayModelName, "gemini-3.1-pro")
    }

    func test_knownModelTokens_coversFullPostIOLineup() {
        // Smoke test against the map directly so accidental deletions
        // surface here even when no .pbtxt text exercises them.
        XCTAssertEqual(AntigravityStateReader.knownModelTokens["MODEL_PLACEHOLDER_M134"], "gemini-3.1-pro")
        XCTAssertEqual(AntigravityStateReader.knownModelTokens["MODEL_PLACEHOLDER_M133"], "gemini-3.5-flash")
        XCTAssertEqual(AntigravityStateReader.knownModelTokens["MODEL_PLACEHOLDER_M132"], "gemini-3-pro")
    }

    func test_parse_pendingMigration() {
        let text = """
        last_selected_agent_model:  MODEL_PLACEHOLDER_M133
        migrate_convos_into_projects:  MIGRATION_STATUS_PENDING
        installation_uuid:  "abc-123"
        """
        let state = AntigravityStateReader.parse(text: text)
        XCTAssertEqual(state.migrationStatus, .pending)
    }

    func test_parse_unknownMigrationStatusFallsBack() {
        let text = """
        migrate_convos_into_projects:  MIGRATION_STATUS_LAUNCH_DAY
        """
        let state = AntigravityStateReader.parse(text: text)
        XCTAssertEqual(state.migrationStatus, .unknown)
    }

    func test_parse_missingMigrationFieldDefaultsUnknown() {
        let text = """
        last_selected_agent_model:  MODEL_PLACEHOLDER_M133
        """
        let state = AntigravityStateReader.parse(text: text)
        XCTAssertEqual(state.migrationStatus, .unknown)
    }

    func test_parse_emptyTextReturnsAllNil() {
        let state = AntigravityStateReader.parse(text: "")
        XCTAssertNil(state.lastSelectedAgentModelToken)
        XCTAssertNil(state.installationUUID)
        XCTAssertEqual(state.migrationStatus, .unknown)
        XCTAssertNil(state.displayModelName)
    }

    func test_parse_unknownModelTokenDisplayedAsRawToken() {
        // Antigravity 2.1 ships M150 → we should pass it through unchanged
        // rather than silently dropping or pretending we know it.
        let text = "last_selected_agent_model:  MODEL_PLACEHOLDER_M150"
        let state = AntigravityStateReader.parse(text: text)
        XCTAssertEqual(state.lastSelectedAgentModelToken, "MODEL_PLACEHOLDER_M150")
        XCTAssertEqual(state.displayModelName, "MODEL_PLACEHOLDER_M150")
    }

    func test_parse_stripsQuotesFromUUID() {
        let state = AntigravityStateReader.parse(text: "installation_uuid:  \"abc-123\"")
        XCTAssertEqual(state.installationUUID, "abc-123")
    }

    func test_parse_handlesUnquotedUUID() {
        // Belt-and-suspenders: future Antigravity versions might omit
        // the quotes on the uuid field.
        let state = AntigravityStateReader.parse(text: "installation_uuid:  abc-123")
        XCTAssertEqual(state.installationUUID, "abc-123")
    }

    func test_parse_skipsCommentsAndBlankLines() {
        let text = """
        # this is a comment

        last_selected_agent_model:  MODEL_PLACEHOLDER_M133
        # another comment
          # indented comment
        installation_uuid:  "xyz"
        """
        let state = AntigravityStateReader.parse(text: text)
        XCTAssertEqual(state.lastSelectedAgentModelToken, "MODEL_PLACEHOLDER_M133")
        XCTAssertEqual(state.installationUUID, "xyz")
    }

    func test_parse_doesNotConfuseNestedKeysWithTopLevel() {
        // The nested `completed_steps:` rows must not poison our `_` parsing.
        // We only consume the top-level keys we care about; verify the parser
        // doesn't break by accidentally matching something nested.
        let state = AntigravityStateReader.parse(text: liveFixture)
        // The nested block's `uids: 23` should not have ended up anywhere.
        XCTAssertEqual(state.lastSelectedAgentModelToken, "MODEL_PLACEHOLDER_M133")
        XCTAssertEqual(state.installationUUID, "fd6a5ba1-7a30-425a-aba1-4f0cdc5b1361")
    }

    func test_parse_handlesTrailingComments() {
        let text = "last_selected_agent_model:  MODEL_PLACEHOLDER_M133  # default"
        let state = AntigravityStateReader.parse(text: text)
        XCTAssertEqual(state.lastSelectedAgentModelToken, "MODEL_PLACEHOLDER_M133")
    }

    // MARK: - File I/O

    func test_read_fromDiskRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity_state-\(UUID().uuidString).pbtxt")
        try liveFixture.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let state = try AntigravityStateReader.read(at: url)
        XCTAssertEqual(state.lastSelectedAgentModelToken, "MODEL_PLACEHOLDER_M133")
        XCTAssertEqual(state.displayModelName, "gemini-3.5-flash")
    }

    func test_read_throwsOnMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pbtxt")
        XCTAssertThrowsError(try AntigravityStateReader.read(at: url))
    }

    // MARK: - Model token lookup

    func test_modelDisplayName_knownTokens() {
        XCTAssertEqual(AntigravityStateReader.modelDisplayName(forToken: "MODEL_PLACEHOLDER_M133"), "gemini-3.5-flash")
        XCTAssertEqual(AntigravityStateReader.modelDisplayName(forToken: "MODEL_PLACEHOLDER_M132"), "gemini-3-pro")
    }

    func test_modelDisplayName_unknownTokenReturnsNil() {
        XCTAssertNil(AntigravityStateReader.modelDisplayName(forToken: "MODEL_PLACEHOLDER_M999"))
    }
}
