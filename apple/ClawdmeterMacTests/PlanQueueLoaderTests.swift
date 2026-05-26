import XCTest
@testable import Clawdmeter

/// Tests for the Continue Plan spawn queue loader.
///
/// Covers:
///   - JSONL line decoding (skipping malformed rows)
///   - assignment registry seeds rows even when JSONL is missing
///   - JSONL items enrich matching assignments with title + files
///   - assignment without a JSONL row gets a synthesized stub
///   - PlanRunner.renderPrompt embeds id / branch / base / acceptance
///   - PlanRunner.escapeForAppleScript escapes both `"` and `\`
final class PlanQueueLoaderTests: XCTestCase {

    // MARK: - PlanItem JSONL parsing

    func test_loadItems_decodesSingleObjectPerLine() throws {
        let jsonl = """
        {"id":"A1","priority":"P1","component":"swiftui-perf","files":["foo.swift"],"effort_human":"0.5d","effort_cc":"1h","title":"Replace 20Hz timer"}
        {"id":"A2","priority":"P2","component":"swiftui-perf","files":["bar.swift","baz.swift"],"effort_human":"1d","effort_cc":"2h","title":"Dedup wallpaper"}
        """
        let url = try writeTempFile(contents: jsonl, name: "tasks-test.jsonl")
        let items = try PlanQueueLoader.loadItems(from: url)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "A1")
        XCTAssertEqual(items[0].files, ["foo.swift"])
        XCTAssertEqual(items[1].files, ["bar.swift", "baz.swift"])
        XCTAssertEqual(items[1].effortCC, "2h")
    }

    func test_loadItems_skipsMalformedLines() throws {
        let jsonl = """
        {"id":"A1","priority":"P1","component":"x","files":[],"effort_human":"1d","effort_cc":"1h","title":"valid"}
        this-is-not-json-at-all
        {"id":"A2","priority":"P1","component":"x","files":[],"effort_human":"1d","effort_cc":"1h","title":"also valid"}
        """
        let url = try writeTempFile(contents: jsonl, name: "tasks-malformed.jsonl")
        let items = try PlanQueueLoader.loadItems(from: url)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map { $0.id }, ["A1", "A2"])
    }

    func test_loadItems_handlesEmptyLines() throws {
        let jsonl = """

        {"id":"A1","priority":"P1","component":"x","files":[],"effort_human":"1d","effort_cc":"1h","title":"valid"}


        """
        let url = try writeTempFile(contents: jsonl, name: "tasks-blanks.jsonl")
        let items = try PlanQueueLoader.loadItems(from: url)
        XCTAssertEqual(items.count, 1)
    }

    // MARK: - PlanQueue construction

    func test_load_buildsRowsForEveryAssignment() throws {
        let repoRoot = try makeTempRepoRoot()
        // No JSONL — assignments should still produce rows (with stubs).
        let queue = PlanQueueLoader.load(repoRoot: repoRoot, jsonlURL: URL(fileURLWithPath: "/tmp/nonexistent-tasks.jsonl"))
        let assignments = PlanAssignmentRegistry.defaults(repoRoot: repoRoot)
        XCTAssertEqual(queue.rows.count, assignments.count)
        // Every row's assignment should match the registry.
        for row in queue.rows {
            XCTAssertNotNil(assignments[row.assignment.planItemId])
        }
    }

    func test_load_synthesizesStubItemWhenJSONLMissingId() throws {
        let repoRoot = try makeTempRepoRoot()
        // JSONL with only an A1 row — no row matches the registry's
        // entries (A5/A6/A11/...). Every queue row should fall back to
        // the synthesized stub.
        let jsonl = """
        {"id":"A1","priority":"P1","component":"x","files":[],"effort_human":"1d","effort_cc":"1h","title":"only a1"}
        """
        let url = try writeTempFile(contents: jsonl, name: "tasks-only-a1.jsonl")
        let queue = PlanQueueLoader.load(repoRoot: repoRoot, jsonlURL: url)
        XCTAssertFalse(queue.rows.isEmpty)
        for row in queue.rows {
            XCTAssertEqual(row.item.component, "follow-up", "missing JSONL row should produce stub with component=follow-up")
            XCTAssertEqual(row.item.id, row.assignment.planItemId)
        }
    }

    func test_load_enrichesAssignmentWhenJSONLHasMatchingId() throws {
        let repoRoot = try makeTempRepoRoot()
        // Synthesize a JSONL row matching one of the registry's
        // assignments so we can verify enrichment lands.
        let assignments = PlanAssignmentRegistry.defaults(repoRoot: repoRoot)
        guard let firstId = assignments.keys.sorted().first else {
            XCTFail("registry empty — nothing to enrich")
            return
        }
        let jsonl = """
        {"id":"\(firstId)","priority":"P1","component":"swiftui-perf","files":["enriched.swift"],"effort_human":"1d","effort_cc":"3h","title":"enriched title"}
        """
        let url = try writeTempFile(contents: jsonl, name: "tasks-enriched.jsonl")
        let queue = PlanQueueLoader.load(repoRoot: repoRoot, jsonlURL: url)
        let row = queue.rows.first { $0.assignment.planItemId == firstId }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.item.title, "enriched title")
        XCTAssertEqual(row?.item.files, ["enriched.swift"])
        XCTAssertEqual(row?.item.effortCC, "3h")
    }

    // MARK: - PlanRunner rendering

    func test_renderPrompt_includesAssignmentMetadata() {
        let row = PlanQueueRow(
            assignment: PlanAssignment(
                planItemId: "A99",
                branch: "perf/a99-test",
                worktreePath: "/tmp/wt",
                baseBranch: "main"
            ),
            item: PlanItem(
                id: "A99",
                priority: "P1",
                component: "swiftui-perf",
                files: ["apple/Foo.swift", "apple/Bar.swift"],
                effortHuman: "1d",
                effortCC: "2h",
                title: "Do the thing",
                sourceFinding: nil
            )
        )
        let prompt = PlanRunner.renderPrompt(for: row)
        XCTAssertTrue(prompt.contains("A99"))
        XCTAssertTrue(prompt.contains("Do the thing"))
        XCTAssertTrue(prompt.contains("perf/a99-test"))
        XCTAssertTrue(prompt.contains("main"))
        XCTAssertTrue(prompt.contains("apple/Foo.swift"))
        XCTAssertTrue(prompt.contains("apple/Bar.swift"))
        XCTAssertTrue(prompt.contains("study-this-codebase-crystalline-shore.md"))
    }

    func test_renderSpawnScript_quotesPaths() {
        let row = PlanQueueRow(
            assignment: PlanAssignment(planItemId: "A1", branch: "b", worktreePath: "/tmp/wt", baseBranch: "main"),
            item: PlanItem(id: "A1", priority: "P1", component: "x", files: [], effortHuman: "1d", effortCC: "1h", title: "t", sourceFinding: nil)
        )
        let script = PlanRunner.renderSpawnScript(promptPath: "/tmp/prompt.md", worktreePath: "/tmp/wt", row: row)
        XCTAssertTrue(script.contains("cd '/tmp/wt'"))
        XCTAssertTrue(script.contains("'/tmp/prompt.md'"))
        XCTAssertTrue(script.contains("claude --dangerously-skip-permissions"))
        XCTAssertTrue(script.hasPrefix("#!/bin/bash"))
    }

    func test_escapeForAppleScript_escapesBackslashesAndQuotes() {
        XCTAssertEqual(PlanRunner.escapeForAppleScript("/tmp/plain"), "/tmp/plain")
        XCTAssertEqual(PlanRunner.escapeForAppleScript("/tmp/with\"quote"), "/tmp/with\\\"quote")
        XCTAssertEqual(PlanRunner.escapeForAppleScript("/tmp/with\\slash"), "/tmp/with\\\\slash")
        XCTAssertEqual(PlanRunner.escapeForAppleScript("\\\""), "\\\\\\\"")
    }

    // MARK: - PlanRepoRoot

    func test_planRepoRoot_defaultUsesDownloadsCCWatch() {
        let home = URL(fileURLWithPath: "/Users/test")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.removeObject(forKey: PlanRepoRoot.userDefaultsKey)
        let root = PlanRepoRoot.resolved(home: home, defaults: defaults)
        XCTAssertEqual(root.path, "/Users/test/Downloads/CC Watch/Clawdmeter")
    }

    func test_planRepoRoot_respectsUserDefaultsOverride() {
        let home = URL(fileURLWithPath: "/Users/test")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("/elsewhere/Clawdmeter", forKey: PlanRepoRoot.userDefaultsKey)
        let root = PlanRepoRoot.resolved(home: home, defaults: defaults)
        XCTAssertEqual(root.path, "/elsewhere/Clawdmeter")
    }

    // MARK: - Helpers

    private func writeTempFile(contents: String, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return url
    }

    private func makeTempRepoRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoRoot = parent.appendingPathComponent("Clawdmeter", isDirectory: true)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return repoRoot
    }
}
