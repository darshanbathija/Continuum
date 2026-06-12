import XCTest
@testable import Clawdmeter

final class RepoFileSearchTests: XCTestCase {
    func testParsePathWithLineNumber() {
        let parsed = RepoFileSearch.parse("Sources/App.swift:42")
        XCTAssertEqual(parsed.path, "Sources/App.swift")
        XCTAssertEqual(parsed.line, 42)
        XCTAssertEqual(parsed.needle, "sources/app.swift")
    }

    func testParsePlainQuery() {
        let parsed = RepoFileSearch.parse("readme")
        XCTAssertEqual(parsed.needle, "readme")
        XCTAssertNil(parsed.line)
        XCTAssertEqual(parsed.path, "readme")
    }

    func testGitFallbackMatchesRecentPathsFirst() {
        let files = ["README.md", "Sources/App.swift", "Package.swift"]
        let matches = RepoFileSearch.matches(
            query: "",
            files: files,
            recents: ["Sources/App.swift"],
            limit: 10
        )
        XCTAssertEqual(matches.first?.path, "Sources/App.swift")
        XCTAssertTrue(matches.first?.isRecent == true)
    }

    func testGitFallbackFuzzyMatchesBasename() {
        let files = ["Sources/Core/App.swift", "Tests/AppTests.swift"]
        let matches = RepoFileSearch.matches(
            query: "apptest",
            files: files,
            recents: [],
            limit: 10
        )
        XCTAssertEqual(matches.first?.path, "Tests/AppTests.swift")
    }

    func testGitFallbackMatchesWithGitRepo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoFileSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("notes.md")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init"]
        git.currentDirectoryURL = root
        try git.run()
        git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        add.arguments = ["add", "notes.md"]
        add.currentDirectoryURL = root
        try add.run()
        add.waitUntilExit()
        XCTAssertEqual(add.terminationStatus, 0)

        let result = RepoFileSearch.matchesWithGit(
            query: "notes",
            repoRoot: root.path,
            recents: [],
            limit: 10
        )
        XCTAssertNil(result.error)
        XCTAssertEqual(result.matches.map(\.path), ["notes.md"])
    }
}
