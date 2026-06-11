import XCTest
@testable import Clawdmeter

final class SkillPluginImporterTests: XCTestCase {
    func test_parseSkillsShURL() throws {
        let source = try SkillPluginImporter.parse("https://skills.sh/vercel-labs/agent-skills")
        XCTAssertEqual(source.cloneSpec, "vercel-labs/agent-skills")
        XCTAssertEqual(source.title, "vercel-labs/agent-skills")
        XCTAssertNil(source.repositorySubpath)
    }

    func test_parseSkillsShBadgeURL() throws {
        let source = try SkillPluginImporter.parse("https://skills.sh/b/vercel-labs/skills")
        XCTAssertEqual(source.cloneSpec, "vercel-labs/skills")
    }

    func test_parseGitHubTreeURL() throws {
        let source = try SkillPluginImporter.parse(
            "https://github.com/vercel-labs/agent-skills/tree/main/skills/web-design-guidelines"
        )
        XCTAssertEqual(source.cloneSpec, "vercel-labs/agent-skills")
        XCTAssertEqual(source.repositorySubpath, "skills/web-design-guidelines")
        XCTAssertEqual(source.requestedSkillName, "web-design-guidelines")
    }

    func test_parseOwnerRepoShorthand() throws {
        let source = try SkillPluginImporter.parse("vercel-labs/agent-skills")
        XCTAssertEqual(source.cloneSpec, "vercel-labs/agent-skills")
        XCTAssertEqual(source.sourceURL, "vercel-labs/agent-skills")
    }

    func test_parseOwnerRepoAtSkill() throws {
        let source = try SkillPluginImporter.parse("vercel-labs/agent-skills@web-design-guidelines")
        XCTAssertEqual(source.cloneSpec, "vercel-labs/agent-skills")
        XCTAssertEqual(source.repositorySubpath, "web-design-guidelines")
        XCTAssertEqual(source.requestedSkillName, "web-design-guidelines")
    }

    func test_resolveSkillsRootPrefersSkillsDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let skillsDir = root.appendingPathComponent("skills", isDirectory: true)
        let skillDir = skillsDir.appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: demo
        description: Demo skill
        ---
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let resolved = try SkillPluginImporter.resolveSkillsRoot(
            cloneRoot: root.path,
            repositorySubpath: nil,
            requestedSkillName: nil
        )
        XCTAssertEqual(resolved, skillsDir.path)
        XCTAssertTrue(SkillCatalog.pluginRootContainsSkills(resolved))
    }

    func test_resolveSkillsRootUsesRepositorySubpath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let skillDir = root.appendingPathComponent("skills/web-design-guidelines", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: web-design-guidelines
        description: Web design skill
        ---
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let resolved = try SkillPluginImporter.resolveSkillsRoot(
            cloneRoot: root.path,
            repositorySubpath: "skills/web-design-guidelines",
            requestedSkillName: "web-design-guidelines"
        )
        XCTAssertEqual(resolved, root.appendingPathComponent("skills").path)
    }

    // MARK: - Security guards

    func test_parseRejectsLeadingDashOwner() {
        // A leading "-" could be parsed as a flag by `gh repo clone <spec>`.
        XCTAssertThrowsError(try SkillPluginImporter.parse("-evil/repo"))
        XCTAssertThrowsError(try SkillPluginImporter.parse("owner/-evil"))
    }

    func test_hasPathTraversal() {
        XCTAssertTrue(SkillPluginImporter.hasPathTraversal("../etc"))
        XCTAssertTrue(SkillPluginImporter.hasPathTraversal("skills/../../x"))
        XCTAssertFalse(SkillPluginImporter.hasPathTraversal("skills/web-design-guidelines"))
    }

    func test_resolveSkillsRootIgnoresTraversalSubpath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDir = root.appendingPathComponent("skills/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: d\n---"
            .write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // A traversal subpath is ignored; resolution falls back to the
        // in-clone skills/ dir rather than escaping the clone root.
        let resolved = try SkillPluginImporter.resolveSkillsRoot(
            cloneRoot: root.path,
            repositorySubpath: "../../../../etc",
            requestedSkillName: nil
        )
        XCTAssertEqual(resolved, root.appendingPathComponent("skills").path)
    }

    // MARK: - Palette dedup (gstack ships the same skills into ~/.claude/skills
    // and ~/.agents/skills/gstack; the palette must show each name once).

    func test_dedupedByIDPrefersClaudeOverGstack() {
        let claude = PaletteCommand(id: "review", label: "review", description: "claude", source: .claudeGlobal, filePath: "/c/review/SKILL.md")
        let gstack = PaletteCommand(id: "review", label: "review", description: "gstack", source: .gstack, filePath: "/g/review/SKILL.md")
        let result = SkillCatalog.dedupedByID([gstack, claude])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.source, .claudeGlobal)
    }

    func test_dedupedByIDKeepsDistinctIds() {
        let a = PaletteCommand(id: "review", label: "review", description: "", source: .gstack, filePath: nil)
        let b = PaletteCommand(id: "qa", label: "qa", description: "", source: .gstack, filePath: nil)
        XCTAssertEqual(SkillCatalog.dedupedByID([a, b]).count, 2)
    }
}
