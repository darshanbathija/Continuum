import XCTest
@testable import ClawdmeterShared

final class ProviderInstanceShellShimTests: XCTestCase {

    func test_commandName_secondaryClaude() {
        let instance = ProviderInstanceId(
            kind: .claude,
            name: "personal",
            homePathOverride: "/tmp/claude-personal"
        )
        XCTAssertEqual(ProviderInstanceShellShim.commandName(for: instance), "claude-personal")
    }

    func test_commandName_primaryIsNil() {
        let primary = ProviderInstanceId.primary(kind: .claude)
        XCTAssertNil(ProviderInstanceShellShim.commandName(for: primary))
    }

    func test_claudeScript_setsConfigDirAndTokenService() throws {
        let instance = ProviderInstanceId(
            kind: .claude,
            name: "work",
            homePathOverride: "/Users/me/Library/Application Support/Clawdmeter/Instances/claude/work"
        )
        let script = try XCTUnwrap(ProviderInstanceShellShim.script(for: instance))
        XCTAssertTrue(script.hasPrefix("#!/usr/bin/env bash\n"))
        XCTAssertTrue(script.contains(ProviderInstanceShellShim.shimMarkerPrefix + "claude/work"))
        XCTAssertTrue(script.contains("export CLAUDE_CONFIG_DIR='/Users/me/Library/Application Support/Clawdmeter/Instances/claude/work'"))
        XCTAssertTrue(script.contains("security find-generic-password -s 'com.clawdmeter.anthropic.token.claude/work'"))
        XCTAssertTrue(script.contains("unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN"))
        XCTAssertTrue(script.contains("export CLAUDE_CODE_OAUTH_TOKEN=\"$TOKEN\""))
        XCTAssertTrue(script.contains("exec \"$CLAUDE_BIN\" \"$@\""))
    }

    func test_codexScript_setsCodexHome() throws {
        let instance = ProviderInstanceId(
            kind: .codex,
            name: "pro",
            homePathOverride: "/tmp/codex-pro"
        )
        let script = try XCTUnwrap(ProviderInstanceShellShim.script(for: instance))
        XCTAssertTrue(script.contains(ProviderInstanceShellShim.shimMarkerPrefix + "codex/pro"))
        XCTAssertTrue(script.contains("export CODEX_HOME='/tmp/codex-pro'"))
        XCTAssertTrue(script.contains("unset OPENAI_API_KEY CODEX_API_KEY"))
        XCTAssertTrue(script.contains("exec \"$CODEX_BIN\" \"$@\""))
    }

    func test_shellSingleQuoted_escapesEmbeddedQuotes() {
        XCTAssertEqual(
            ProviderInstanceShellShim.shellSingleQuoted("it's fine"),
            "'it'\"'\"'s fine'"
        )
    }

    func test_geminiKindHasNoShim() {
        let instance = ProviderInstanceId(
            kind: .gemini,
            name: "work",
            homePathOverride: "/tmp/gemini-work"
        )
        XCTAssertNil(ProviderInstanceShellShim.script(for: instance))
    }
}
