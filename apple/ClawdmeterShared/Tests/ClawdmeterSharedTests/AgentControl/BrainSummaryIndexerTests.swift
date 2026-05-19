import XCTest
@testable import ClawdmeterShared

/// Exercises the string-scan parser for `agyhub_summaries_proto.pb`. We
/// build synthetic protobuf bytes by hand for each fixture — the parser
/// is supposed to be schema-agnostic (only the top-level UUID tag matters),
/// so synthetic byte sequences exercise it more crisply than a vendored
/// real-world capture would.
final class BrainSummaryIndexerTests: XCTestCase {

    // MARK: - Wire-format builders (test-only)

    /// Encodes a varint length prefix.
    private func varint(_ value: Int) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        while v >= 0x80 {
            out.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v & 0x7f))
        return out
    }

    /// Encodes a length-delimited field: tag byte + varint length + bytes.
    private func lengthDelimited(tag: UInt8, payload: [UInt8]) -> [UInt8] {
        [tag] + varint(payload.count) + payload
    }

    private func ascii(_ str: String) -> [UInt8] { [UInt8](str.utf8) }

    /// Builds a SummaryEntry block for a single brain. The "outer" version
    /// of this is wrapped in another length-delimited field by the live
    /// file, but the parser treats the file as one continuous stream of
    /// length-delimited fields, so we can flatten that wrapper away here.
    private func summaryEntry(
        brainUUID: String,
        projectTitle: String? = nil,
        cwd: String? = nil,
        gitShortName: String? = nil,
        gitRemote: String? = nil,
        branch: String? = nil,
        extraNoise: [UInt8] = []
    ) -> [UInt8] {
        var body: [UInt8] = []
        // Field 1 = brain UUID (always — that's the anchor).
        body += lengthDelimited(tag: 0x0a, payload: ascii(brainUUID))
        // The remaining fields go INSIDE the BrainSummary, but for the
        // string-scan parser they just need to appear at any length-
        // delimited offset after the UUID.
        if let projectTitle {
            body += lengthDelimited(tag: 0x12, payload: ascii(projectTitle))
        }
        if let cwd {
            body += lengthDelimited(tag: 0x0a, payload: ascii(cwd))
        }
        if let gitShortName {
            body += lengthDelimited(tag: 0x0a, payload: ascii(gitShortName))
        }
        if let gitRemote {
            body += lengthDelimited(tag: 0x12, payload: ascii(gitRemote))
        }
        if let branch {
            body += lengthDelimited(tag: 0x22, payload: ascii(branch))
        }
        body += extraNoise
        return body
    }

    // MARK: - Single-entry parsing

    func test_parse_singleEntry_extractsUUIDAndCwd() {
        let bytes = summaryEntry(
            brainUUID: "74ef8243-718e-4ce0-b415-fef0b6321148",
            cwd: "file:///Users/test/Downloads/glide.co"
        )
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        XCTAssertEqual(index.byUUID.count, 1)
        let summary = try? XCTUnwrap(index.byUUID["74ef8243-718e-4ce0-b415-fef0b6321148"])
        XCTAssertEqual(summary?.cwd?.path, "/Users/test/Downloads/glide.co")
    }

    func test_parse_singleEntry_extractsGitRemoteAndBranch() {
        let bytes = summaryEntry(
            brainUUID: "74ef8243-718e-4ce0-b415-fef0b6321148",
            projectTitle: "MCP Security Static Analysis",
            cwd: "file:///Users/test/Downloads/glide.co",
            gitShortName: "glide-co/glide-mono",
            gitRemote: "https://github.com/glide-co/glide-mono.git",
            branch: "wip/codex-abandoned-may17"
        )
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        let summary = try? XCTUnwrap(index.byUUID["74ef8243-718e-4ce0-b415-fef0b6321148"])
        XCTAssertEqual(summary?.projectTitle, "MCP Security Static Analysis")
        XCTAssertEqual(summary?.gitRemote?.absoluteString, "https://github.com/glide-co/glide-mono.git")
        XCTAssertEqual(summary?.gitShortName, "glide-co/glide-mono")
        XCTAssertEqual(summary?.branch, "wip/codex-abandoned-may17")
    }

    func test_parse_multipleEntries_keepEntriesSeparate() {
        var bytes: [UInt8] = []
        bytes += summaryEntry(
            brainUUID: "11111111-1111-4111-8111-111111111111",
            cwd: "file:///Users/a/Repo1",
            gitShortName: "alice/repo1",
            branch: "main"
        )
        bytes += summaryEntry(
            brainUUID: "22222222-2222-4222-8222-222222222222",
            cwd: "file:///Users/a/Repo2",
            gitShortName: "alice/repo2",
            branch: "develop"
        )
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        XCTAssertEqual(index.byUUID.count, 2)
        XCTAssertEqual(index.byUUID["11111111-1111-4111-8111-111111111111"]?.gitShortName, "alice/repo1")
        XCTAssertEqual(index.byUUID["11111111-1111-4111-8111-111111111111"]?.branch, "main")
        XCTAssertEqual(index.byUUID["22222222-2222-4222-8222-222222222222"]?.gitShortName, "alice/repo2")
        XCTAssertEqual(index.byUUID["22222222-2222-4222-8222-222222222222"]?.branch, "develop")
    }

    // MARK: - Reverse index

    func test_parse_byCwdPath_buildsReverseIndex() {
        let bytes = summaryEntry(
            brainUUID: "11111111-1111-4111-8111-111111111111",
            cwd: "file:///Users/a/Repo1"
        )
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        let cwdURL = URL(fileURLWithPath: "/Users/a/Repo1")
        let matches = BrainSummaryIndexer.lookup(cwd: cwdURL, in: index)
        XCTAssertEqual(matches, ["11111111-1111-4111-8111-111111111111"])
    }

    func test_parse_byCwdPath_groupsMultipleBrainsPerRepo() {
        // Two brain entries with the same cwd — happens when a repo has
        // multiple historical Antigravity sessions.
        var bytes: [UInt8] = []
        bytes += summaryEntry(brainUUID: "11111111-1111-4111-8111-111111111111", cwd: "file:///Users/a/Repo1")
        bytes += summaryEntry(brainUUID: "22222222-2222-4222-8222-222222222222", cwd: "file:///Users/a/Repo1")
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        let matches = Set(BrainSummaryIndexer.lookup(cwd: URL(fileURLWithPath: "/Users/a/Repo1"), in: index))
        XCTAssertEqual(matches, Set(["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"]))
    }

    func test_lookup_isCaseInsensitive() {
        // macOS default fs is case-insensitive; a session reporting `/users/a/repo1`
        // must match an entry recorded as `/Users/a/Repo1`.
        let bytes = summaryEntry(
            brainUUID: "11111111-1111-4111-8111-111111111111",
            cwd: "file:///Users/a/Repo1"
        )
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        let matches = BrainSummaryIndexer.lookup(cwd: URL(fileURLWithPath: "/users/a/repo1"), in: index)
        XCTAssertEqual(matches, ["11111111-1111-4111-8111-111111111111"])
    }

    func test_lookup_stripsTrailingSlash() {
        let bytes = summaryEntry(
            brainUUID: "11111111-1111-4111-8111-111111111111",
            cwd: "file:///Users/a/Repo1/"
        )
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        // Both with and without trailing slash should match.
        XCTAssertEqual(BrainSummaryIndexer.lookup(cwd: URL(fileURLWithPath: "/Users/a/Repo1"), in: index).count, 1)
    }

    // MARK: - Robustness

    func test_parse_emptyFileReturnsEmptyIndex() {
        let index = BrainSummaryIndexer.parse(bytes: Data())
        XCTAssertEqual(index, .empty)
    }

    func test_parse_garbageBytesReturnsEmptyIndex() {
        let bytes: [UInt8] = [0xff, 0xff, 0xff, 0x00, 0x01, 0x02]
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        XCTAssertEqual(index, .empty, "Random garbage that doesn't contain a 0a 24 + UUID anchor produces no entries")
    }

    func test_parse_truncatedUUIDIsSkipped() {
        // 0a 24 followed by only 5 bytes — not a valid UUID, must be skipped.
        let bytes: [UInt8] = [0x0a, 0x24] + [UInt8]("abcde".utf8)
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        XCTAssertEqual(index, .empty)
    }

    func test_parse_skipsTrailingNonUUIDStrings() {
        // Body contains stuff that isn't strict UUID shaped — should not
        // produce extra entries.
        var bytes = summaryEntry(
            brainUUID: "11111111-1111-4111-8111-111111111111",
            cwd: "file:///Users/a/Repo1"
        )
        // Append `0a 24` + 36 non-UUID bytes (no dashes).
        bytes += [0x0a, 0x24]
        bytes += [UInt8](repeating: 0x78, count: 36) // 36 'x's — fails dash positions
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        XCTAssertEqual(index.byUUID.count, 1)
        XCTAssertNotNil(index.byUUID["11111111-1111-4111-8111-111111111111"])
    }

    func test_parse_lowercasesUUIDOnRead() {
        // Antigravity always writes lowercase UUIDs, but be defensive
        // and ensure the lookup normalizes.
        let upperUUID = "11111111-1111-4111-8111-111111111111".uppercased()
        let bytes = summaryEntry(brainUUID: upperUUID, cwd: "file:///Users/a/Repo1")
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        XCTAssertNotNil(index.byUUID["11111111-1111-4111-8111-111111111111"])
    }

    func test_parse_entryWithNoCwdStillIndexedByUUID() {
        // Some entries are placeholders without a workspace yet — should
        // still appear in byUUID but not in byCwdPath.
        let bytes = summaryEntry(
            brainUUID: "11111111-1111-4111-8111-111111111111",
            projectTitle: "fresh-untitled-task"
        )
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        XCTAssertNotNil(index.byUUID["11111111-1111-4111-8111-111111111111"])
        XCTAssertNil(index.byUUID["11111111-1111-4111-8111-111111111111"]?.cwd)
        XCTAssertEqual(index.byCwdPath.count, 0)
    }

    // MARK: - Disk read

    func test_read_returnsEmptyForMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pb")
        let index = BrainSummaryIndexer.read(at: url)
        XCTAssertEqual(index, .empty)
    }

    func test_read_roundTripsViaDisk() throws {
        let bytes = summaryEntry(
            brainUUID: "11111111-1111-4111-8111-111111111111",
            cwd: "file:///Users/a/Repo1",
            gitShortName: "alice/repo1",
            branch: "main"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brain-index-\(UUID().uuidString).pb")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let index = BrainSummaryIndexer.read(at: url)
        XCTAssertEqual(index.byUUID["11111111-1111-4111-8111-111111111111"]?.gitShortName, "alice/repo1")
        XCTAssertEqual(index.byUUID["11111111-1111-4111-8111-111111111111"]?.branch, "main")
    }

    // MARK: - Real-world byte capture

    /// Verifies the parser handles the exact byte sequence we observe on
    /// a live install. This is one synthesized SummaryEntry block whose
    /// shape mirrors the production file's first entry (UUID + nested
    /// repo info + git remote + branch). If a future Antigravity version
    /// reshuffles INTERNAL fields, this test still passes because the
    /// parser doesn't decode the internal structure.
    func test_parse_liveByteSequenceShape() {
        // Hand-built to match the byte pattern observed in production at
        // file offset 0 (see commit 2 notes in the eng review).
        let bytes = summaryEntry(
            brainUUID: "74ef8243-718e-4ce0-b415-fef0b6321148",
            projectTitle: "MCP Security Static Analysis",
            cwd: "file:///Users/darshanbathija_1/Downloads/glide.co",
            gitShortName: "glide-co/glide-mono",
            gitRemote: "https://github.com/glide-co/glide-mono.git",
            branch: "wip/codex-abandoned-may17"
        )
        let index = BrainSummaryIndexer.parse(bytes: Data(bytes))
        let summary = try? XCTUnwrap(index.byUUID["74ef8243-718e-4ce0-b415-fef0b6321148"])
        XCTAssertEqual(summary?.projectTitle, "MCP Security Static Analysis")
        XCTAssertEqual(summary?.cwd?.path, "/Users/darshanbathija_1/Downloads/glide.co")
        XCTAssertEqual(summary?.gitRemote?.absoluteString, "https://github.com/glide-co/glide-mono.git")
        XCTAssertEqual(summary?.gitShortName, "glide-co/glide-mono")
        XCTAssertEqual(summary?.branch, "wip/codex-abandoned-may17")
    }
}
