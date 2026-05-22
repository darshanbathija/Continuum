import XCTest
import ClawdmeterShared
@testable import Clawdmeter

/// v0.23 (Chat V2 — T7 verification): asserts the spawn argv assembly
/// for Claude Deep Research is what the verification gate
/// (`tools/verify-deep-research.sh`) expects. If a future refactor
/// drops `--allowedTools` or the `--append-system-prompt` path, this
/// test fails at CI time instead of silently degrading DR to a normal
/// send.
@MainActor
final class DeepResearchArgvTests: XCTestCase {

    /// Skips if the test machine doesn't have `claude` on PATH —
    /// `ShellRunner.locateBinary` returns nil and `claudeArgv` returns
    /// nil. We assert the *shape* on the assumption claude is present;
    /// the verification gate covers no-binary paths separately.
    func test_claudeArgv_with_deepResearch_includes_allowedTools_and_systemPrompt() throws {
        guard let argv = AgentSpawner.claudeArgv(
            model: "claude-opus-4-7",
            deepResearch: true
        ) else {
            throw XCTSkip("claude binary not on PATH — skipping argv shape test")
        }
        // --allowedTools must be set with the WebSearch/WebFetch family.
        XCTAssertTrue(argv.contains("--allowedTools"),
            "Deep Research argv must include --allowedTools")
        if let idx = argv.firstIndex(of: "--allowedTools") {
            let value = argv[argv.index(after: idx)]
            XCTAssertTrue(value.contains("WebSearch"))
            XCTAssertTrue(value.contains("WebFetch"))
        }
        // --effort must be max (DR overrides caller-supplied effort).
        if let idx = argv.firstIndex(of: "--effort") {
            let value = argv[argv.index(after: idx)]
            XCTAssertEqual(value, ReasoningEffort.max.claudeFlagValue,
                "Deep Research argv must use --effort \(ReasoningEffort.max.claudeFlagValue)")
        } else {
            XCTFail("Deep Research argv must set --effort")
        }
        // --append-system-prompt must be set — the bundle resource is
        // shipped in production; tests run against the same .app, so the
        // resource lookup succeeds and the flag appears with the prompt
        // text as the value.
        XCTAssertTrue(argv.contains("--append-system-prompt"),
            "Deep Research argv must include --append-system-prompt with the bundled prompt")
    }

    func test_claudeArgv_without_deepResearch_omits_dr_flags() throws {
        guard let argv = AgentSpawner.claudeArgv(model: "claude-opus-4-7") else {
            throw XCTSkip("claude binary not on PATH")
        }
        XCTAssertFalse(argv.contains("--allowedTools"),
            "Non-DR argv must NOT carry --allowedTools (avoid silent DR-mode)")
        XCTAssertFalse(argv.contains("--append-system-prompt"),
            "Non-DR argv must NOT carry --append-system-prompt")
    }

    func test_deepResearch_systemPrompt_resource_is_bundled() {
        let prompt = AgentSpawner.loadDeepResearchPrompt()
        XCTAssertNotNil(prompt, "deep-research-prompt.txt must be bundled in the .app")
        XCTAssertTrue(prompt?.contains("[research-step]") ?? false,
            "system prompt must define the [research-step] N. convention the V2 UI extracts")
        // The bundled prompt uses uppercase "CITE" as one of its 6-step
        // section headers; assert against that exact contract.
        XCTAssertTrue(prompt?.contains("CITE") ?? false,
            "system prompt must instruct the agent to cite sources (looks for the CITE step header)")
    }
}
