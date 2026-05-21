import XCTest
@testable import ClawdmeterShared

/// Tests for `AntigravityProjectResolver` per Phase 0.5 / D6:
///   - Parse `~/.gemini/config/projects/<uuid>.json` records
///   - Extract `projectResources.resources[].gitFolder.folderUri`
///   - URL-decode percent-escapes (e.g. CC%20Watch → CC Watch)
///   - Match against `RepoIdentity.normalize(session.repoKey)`
///   - Skip outside-of-project sentinels + records with null projectResources
///   - Honor `gitFolder.allowWrite`
///   - Cache + invalidate behavior
final class AntigravityProjectResolverTests: XCTestCase {

    var tempDir: URL!
    var reposRoot: URL!
    var resolver: AntigravityProjectResolver!

    override func setUp() async throws {
        try await super.setUp()
        // Each test runs in its own tmp projects/ dir + separate
        // reposRoot for repo fixtures (so RepoIdentity.normalize
        // discovers `.git` and returns the path verbatim instead of
        // bucketing into `RepoKey.other`).
        let session = UUID().uuidString
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agp-resolver-test-\(session)-projects")
        reposRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agp-resolver-test-\(session)-repos")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reposRoot, withIntermediateDirectories: true)
        resolver = AntigravityProjectResolver(projectsDir: tempDir)
    }

    /// Create a fake repo at `<reposRoot>/<name>` with a `.git` directory
    /// so `RepoIdentity.normalize` returns the path verbatim rather than
    /// bucketing as `RepoKey.other`. Returns the absolute path.
    @discardableResult
    private func makeRepoDir(_ name: String) throws -> String {
        let repoDir = reposRoot.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        let gitDir = repoDir.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        return repoDir.path
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        if let reposRoot { try? FileManager.default.removeItem(at: reposRoot) }
        try await super.tearDown()
    }

    // MARK: - decodeURI

    func test_decodeURI_stripsFilePrefixAndDecodes() {
        XCTAssertEqual(
            AntigravityProjectResolver.decodeURI("file:///Users/dev/Downloads/CC%20Watch"),
            "/Users/dev/Downloads/CC Watch"
        )
        XCTAssertEqual(
            AntigravityProjectResolver.decodeURI("file:///Users/dev/Downloads/glide.co"),
            "/Users/dev/Downloads/glide.co"
        )
        XCTAssertEqual(
            AntigravityProjectResolver.decodeURI("file:///Users/dev/Downloads/Defx%20V3"),
            "/Users/dev/Downloads/Defx V3"
        )
    }

    func test_decodeURI_rejectsNonFileSchemes() {
        XCTAssertNil(AntigravityProjectResolver.decodeURI("https://example.com/repo"))
        XCTAssertNil(AntigravityProjectResolver.decodeURI("not-a-uri"))
        XCTAssertNil(AntigravityProjectResolver.decodeURI(""))
    }

    // MARK: - parseProject (single file)

    func test_parseProject_validRecordExtractsAllFields() throws {
        let projectId = "459a1414-c6c1-4560-93cb-3a5cf89fe70d"
        let repoPath = try makeRepoDir("CC Watch")
        let json = #"""
        {
          "id": "\#(projectId)",
          "name": "CC Watch",
          "projectResources": {
            "resources": [
              {
                "gitFolder": {
                  "folderUri": "file://\#(repoPath.replacingOccurrences(of: " ", with: "%20"))",
                  "allowWrite": true
                }
              }
            ]
          },
          "settings": {
            "autoExecutionPolicy": "CASCADE_COMMANDS_AUTO_EXECUTION_OFF"
          }
        }
        """#
        let url = tempDir.appendingPathComponent("\(projectId).json")
        try json.data(using: .utf8)!.write(to: url)

        let info = resolver.parseProject(at: url)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.id, projectId)
        XCTAssertEqual(info?.name, "CC Watch")
        XCTAssertEqual(info?.allowWrite, true)
        XCTAssertEqual(info?.repoKey, repoPath)
    }

    func test_parseProject_skipsOutsideOfProjectSentinel() throws {
        let json = #"""
        { "id": "outside-of-project", "name": "Outside of Project", "permissionGrants": {} }
        """#
        let url = tempDir.appendingPathComponent("outside-of-project.json")
        try json.data(using: .utf8)!.write(to: url)
        XCTAssertNil(resolver.parseProject(at: url))
    }

    func test_parseProject_skipsNullProjectResources() throws {
        let json = #"""
        { "id": "abc-123", "name": "Phantom", "projectResources": null }
        """#
        let url = tempDir.appendingPathComponent("abc-123.json")
        try json.data(using: .utf8)!.write(to: url)
        XCTAssertNil(resolver.parseProject(at: url))
    }

    func test_parseProject_skipsEmptyResourcesArray() throws {
        let json = #"""
        { "id": "abc-123", "name": "Empty", "projectResources": { "resources": [] } }
        """#
        let url = tempDir.appendingPathComponent("abc-123.json")
        try json.data(using: .utf8)!.write(to: url)
        XCTAssertNil(resolver.parseProject(at: url))
    }

    func test_parseProject_defaultsAllowWriteTrueWhenAbsent() throws {
        // Some older project records omit the `allowWrite` key.
        let json = #"""
        {
          "id": "abc-123",
          "name": "Legacy",
          "projectResources": {
            "resources": [
              { "gitFolder": { "folderUri": "file:///tmp/legacy" } }
            ]
          }
        }
        """#
        let url = tempDir.appendingPathComponent("abc-123.json")
        try json.data(using: .utf8)!.write(to: url)
        let info = resolver.parseProject(at: url)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.allowWrite, true)
    }

    func test_parseProject_honorsAllowWriteFalse() throws {
        let json = #"""
        {
          "id": "abc-123",
          "name": "Read Only",
          "projectResources": {
            "resources": [
              { "gitFolder": { "folderUri": "file:///tmp/ro", "allowWrite": false } }
            ]
          }
        }
        """#
        let url = tempDir.appendingPathComponent("abc-123.json")
        try json.data(using: .utf8)!.write(to: url)
        let info = resolver.parseProject(at: url)
        XCTAssertEqual(info?.allowWrite, false)
    }

    func test_parseProject_skipsResourceWithoutGitFolder() throws {
        // Antigravity may add other resource types in the future
        // (remote repos, S3, etc.). Skip them rather than crash.
        let json = #"""
        {
          "id": "abc-123",
          "name": "Remote",
          "projectResources": {
            "resources": [
              { "remoteRepo": { "url": "git@github.com:foo/bar.git" } }
            ]
          }
        }
        """#
        let url = tempDir.appendingPathComponent("abc-123.json")
        try json.data(using: .utf8)!.write(to: url)
        XCTAssertNil(resolver.parseProject(at: url))
    }

    func test_parseProject_skipsMalformedJSON() throws {
        let url = tempDir.appendingPathComponent("malformed.json")
        try "{ not valid json".data(using: .utf8)!.write(to: url)
        XCTAssertNil(resolver.parseProject(at: url))
    }

    // MARK: - resolve (full lookup)

    func test_resolve_findsProjectMatchingRepoKey() async throws {
        let projectId = "459a1414-c6c1-4560-93cb-3a5cf89fe70d"
        let tmpRepo = try makeRepoDir("test-repo")
        let json = #"""
        {
          "id": "\#(projectId)",
          "name": "Test Repo",
          "projectResources": {
            "resources": [
              { "gitFolder": { "folderUri": "file://\#(tmpRepo)", "allowWrite": true } }
            ]
          }
        }
        """#
        try json.data(using: .utf8)!.write(to: tempDir.appendingPathComponent("\(projectId).json"))

        let info = await resolver.resolve(forRepoKey: tmpRepo)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.id, projectId)
        XCTAssertEqual(info?.name, "Test Repo")
    }

    func test_resolve_returnsNilForUnknownRepo() async throws {
        // Empty projects dir.
        let info = await resolver.resolve(forRepoKey: "/Users/dev/some-other-repo")
        XCTAssertNil(info)
    }

    func test_resolve_handlesURLEncodedPaths() async throws {
        // Path with a space — Antigravity stores it URL-encoded.
        // Resolver must round-trip cleanly.
        let projectId = "abc-with-spaces"
        let repoPath = try makeRepoDir("CC Watch")
        let urlEncodedPath = repoPath.replacingOccurrences(of: " ", with: "%20")
        let json = #"""
        {
          "id": "\#(projectId)",
          "name": "CC Watch",
          "projectResources": {
            "resources": [
              { "gitFolder": { "folderUri": "file://\#(urlEncodedPath)", "allowWrite": true } }
            ]
          }
        }
        """#
        try json.data(using: .utf8)!.write(to: tempDir.appendingPathComponent("\(projectId).json"))

        let info = await resolver.resolve(forRepoKey: repoPath)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.id, projectId)
    }

    func test_resolve_multipleProjectsIndexedIndependently() async throws {
        let p1 = "111"
        let p2 = "222"
        let p3 = "outside-of-project"
        let path1 = try makeRepoDir("repo-a")
        let path2 = try makeRepoDir("repo-b")

        try project(id: p1, name: "RepoA", folderUri: "file://\(path1)")
            .write(to: tempDir.appendingPathComponent("\(p1).json"))
        try project(id: p2, name: "RepoB", folderUri: "file://\(path2)")
            .write(to: tempDir.appendingPathComponent("\(p2).json"))
        try Data("""
        { "id": "\(p3)", "name": "Outside" }
        """.utf8).write(to: tempDir.appendingPathComponent("\(p3).json"))

        let infoA = await resolver.resolve(forRepoKey: path1)
        let infoB = await resolver.resolve(forRepoKey: path2)
        let infoOutside = await resolver.resolve(forRepoKey: "/somewhere/unrelated")
        XCTAssertEqual(infoA?.id, p1)
        XCTAssertEqual(infoB?.id, p2)
        XCTAssertNil(infoOutside)
    }

    // MARK: - cache + invalidate

    func test_invalidate_forcesReindexOnNextResolve() async throws {
        let pid = "cache-test"
        let path = try makeRepoDir("cache-repo")
        try project(id: pid, name: "Test", folderUri: "file://\(path)")
            .write(to: tempDir.appendingPathComponent("\(pid).json"))

        // First resolve: indexes.
        let first = await resolver.resolve(forRepoKey: path)
        XCTAssertNotNil(first)

        // Delete the file under the resolver.
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("\(pid).json"))

        // Without invalidate, cached entry still found (until TTL).
        let cached = await resolver.resolve(forRepoKey: path)
        XCTAssertNotNil(cached)

        // After invalidate, cache is empty.
        await resolver.invalidate()
        let afterInvalidate = await resolver.resolve(forRepoKey: path)
        XCTAssertNil(afterInvalidate)
    }

    func test_allProjects_listsEverythingInDir() async throws {
        let r1 = try makeRepoDir("one")
        let r2 = try makeRepoDir("two")
        try project(id: "p1", name: "One", folderUri: "file://\(r1)")
            .write(to: tempDir.appendingPathComponent("p1.json"))
        try project(id: "p2", name: "Two", folderUri: "file://\(r2)")
            .write(to: tempDir.appendingPathComponent("p2.json"))

        let all = await resolver.allProjects()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains(where: { $0.id == "p1" }))
        XCTAssertTrue(all.contains(where: { $0.id == "p2" }))
    }

    // MARK: - Helpers

    private func project(id: String, name: String, folderUri: String, allowWrite: Bool = true) -> Data {
        let json = #"""
        {
          "id": "\#(id)",
          "name": "\#(name)",
          "projectResources": {
            "resources": [
              { "gitFolder": { "folderUri": "\#(folderUri)", "allowWrite": \#(allowWrite) } }
            ]
          }
        }
        """#
        return Data(json.utf8)
    }
}

private extension Data {
    func write(to url: URL) throws {
        try self.write(to: url, options: .atomic)
    }
}
