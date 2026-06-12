import XCTest
import ClawdmeterShared
@testable import Clawdmeter

final class FffAgentSearchProvisioningTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fff-agent-provision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func test_mergeCodexMCPSection_appendsWhenMissing() throws {
        let mcpBinary = tempRoot.appendingPathComponent("fff-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: mcpBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mcpBinary.path)

        let configURL = tempRoot.appendingPathComponent("config.toml")
        FffAgentSearchProvisioning.mergeCodexMCPSection(into: configURL, command: mcpBinary.path)

        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[mcp_servers.fff]"))
        XCTAssertTrue(text.contains("command = \"\(mcpBinary.path)\""))
    }

    func test_mergeCodexMCPSection_replacesExistingCommand() throws {
        let mcpBinary = tempRoot.appendingPathComponent("fff-mcp")
        try Data("#!/bin/sh\n".utf8).write(to: mcpBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mcpBinary.path)

        let configURL = tempRoot.appendingPathComponent("config.toml")
        try """
        model = "gpt-5.5"

        [mcp_servers.fff]
        command = "/old/path/fff-mcp"

        [mcp_servers.other]
        command = "other-mcp"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        FffAgentSearchProvisioning.mergeCodexMCPSection(into: configURL, command: mcpBinary.path)

        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("command = \"\(mcpBinary.path)\""))
        XCTAssertFalse(text.contains("/old/path/fff-mcp"))
        XCTAssertTrue(text.contains("[mcp_servers.other]"))
    }

    func test_mergeCodexMCPSection_keepsEscapedExistingCommandSection() throws {
        let command = #"/tmp/fff "quoted"/fff-mcp"#
        let configURL = tempRoot.appendingPathComponent("config.toml")
        try """
        [mcp_servers.fff]
        command = "/tmp/fff \\"quoted\\"/fff-mcp"
        args = ["--keep"]

        [mcp_servers.other]
        command = "other-mcp"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        FffAgentSearchProvisioning.mergeCodexMCPSection(into: configURL, command: command)

        let text = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#"command = "/tmp/fff \"quoted\"/fff-mcp""#))
        XCTAssertTrue(text.contains(#"args = ["--keep"]"#))
        XCTAssertTrue(text.contains("[mcp_servers.other]"))
    }

    func test_codexHome_prefersEnvOverride() {
        let home = FffAgentSearchProvisioning.codexHome(from: ["CODEX_HOME": "/tmp/codex-pro"])
        XCTAssertEqual(home.path, "/tmp/codex-pro")
    }

    func test_openCodeEnvironmentOverrides_whenBundledConfigPresent() throws {
        guard let config = FffAgentSearchProvisioning.bundledOpenCodeConfigURL() else {
            throw XCTSkip("bundled opencode-fff config unavailable in test bundle")
        }
        let overrides = FffAgentSearchProvisioning.openCodeEnvironmentOverrides()
        XCTAssertEqual(overrides["OPENCODE_CONFIG"], config.path)
        XCTAssertEqual(overrides["OPENCODE_CONFIG_DIR"], config.deletingLastPathComponent().path)
    }

    func test_codeClaudeArgv_includesMCPConfigWhenBundled() throws {
        try XCTSkipIf(ShellRunner.locateBinary("claude") == nil,
                      "claude binary unavailable on PATH; CI skip")
        try XCTSkipIf(FffAgentSearchProvisioning.bundledMCPBinaryPath() == nil,
                      "bundled fff-mcp unavailable in test bundle")

        let session = AgentSession(
            id: UUID(),
            repoKey: "/Users/foo/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: "opus",
            goal: nil,
            worktreePath: "/Users/foo/repo/.claude/worktrees/oslo",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 0,
            mode: .local,
            kind: .code
        )
        let argv = AgentSpawner.argv(for: session)
        guard let mcpIndex = argv.firstIndex(of: "--mcp-config"), mcpIndex + 1 < argv.count else {
            return XCTFail("code Claude spawn should pass --mcp-config when bundled fff-mcp is present")
        }
        XCTAssertFalse(argv.contains("--strict-mcp-config"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: argv[mcpIndex + 1]))
    }

    func test_chatClaudeArgv_usesStrictMCPNotBundledConfig() throws {
        try XCTSkipIf(ShellRunner.locateBinary("claude") == nil,
                      "claude binary unavailable on PATH; CI skip")

        let session = AgentSession(
            id: UUID(),
            repoKey: nil,
            repoDisplayName: "Chat — claude",
            agent: .claude,
            model: "opus",
            goal: nil,
            worktreePath: "/tmp/chat-sessions/\(UUID().uuidString)",
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 0,
            mode: .local,
            kind: .chat
        )
        let argv = AgentSpawner.argv(for: session)
        XCTAssertTrue(argv.contains("--strict-mcp-config"))
        XCTAssertFalse(argv.contains("--mcp-config"))
    }
}
