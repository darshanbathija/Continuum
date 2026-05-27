import XCTest
@testable import ClawdmeterShared

/// E3 #2 regression test — locks the exact argv list the Mac spawner
/// passes to the Gemini CLI. Catches future flag drift: if `--prompt`
/// is silently renamed or `--approval-mode` becomes `--approval`, this
/// test fires before the bug ships and a user reports "Gemini sessions
/// won't start."
///
/// Test lives in shared because `AgentSpawner.geminiArgv` is the only
/// thin Mac-side adapter around `GeminiArgvBuilder.argv(...)` — the
/// actual flag knowledge sits in the shared builder. The Mac adapter is
/// covered indirectly: if its call site disagreed with the builder
/// signature, the Mac target wouldn't build.
final class AgentSpawnerGeminiArgvTests: XCTestCase {

    private let binary = "/opt/homebrew/bin/gemini"

    func test_defaultInvocation_modelOnly() {
        let argv = GeminiArgvBuilder.argv(
            geminiBinary: binary,
            model: "gemini-3.1-pro-high"
        )
        XCTAssertEqual(argv, [binary, "-m", "gemini-3.1-pro-high"])
    }

    func test_planMode_emitsApprovalModePlan() {
        let argv = GeminiArgvBuilder.argv(
            geminiBinary: binary,
            model: "gemini-3.1-pro-high",
            planMode: true
        )
        XCTAssertEqual(argv, [binary, "-m", "gemini-3.1-pro-high", "--approval-mode", "plan"])
    }

    func test_autopilot_emitsApprovalModeYolo() {
        let argv = GeminiArgvBuilder.argv(
            geminiBinary: binary,
            model: "gemini-3.1-pro-high",
            autopilot: true
        )
        XCTAssertEqual(argv, [binary, "-m", "gemini-3.1-pro-high", "--approval-mode", "yolo"])
    }

    func test_acceptEdits_emitsApprovalModeAutoEdit() {
        let argv = GeminiArgvBuilder.argv(
            geminiBinary: binary,
            model: "gemini-3.1-pro-high",
            acceptEdits: true
        )
        XCTAssertEqual(argv, [binary, "-m", "gemini-3.1-pro-high", "--approval-mode", "auto_edit"])
    }

    /// Precedence regression: plan beats autopilot. Without explicit
    /// precedence, a user who tapped Plan mode WHILE autopilot was
    /// trusted would get YOLO (write-anywhere) instead of plan
    /// (read-only) — a destructive UI confusion.
    func test_planAndAutopilot_planWins() {
        let argv = GeminiArgvBuilder.argv(
            geminiBinary: binary,
            model: "gemini-3.1-pro-high",
            planMode: true,
            autopilot: true,
            acceptEdits: true
        )
        // Only one --approval-mode flag should appear, and it must be plan.
        let count = argv.filter { $0 == "--approval-mode" }.count
        XCTAssertEqual(count, 1, "Exactly one --approval-mode flag")
        XCTAssertTrue(argv.contains("plan"))
        XCTAssertFalse(argv.contains("yolo"))
        XCTAssertFalse(argv.contains("auto_edit"))
    }

    func test_resumeSessionId_emitsResumeFlag() {
        let argv = GeminiArgvBuilder.argv(
            geminiBinary: binary,
            model: "gemini-3-flash",
            resumeSessionId: "abc-123-uuid"
        )
        XCTAssertEqual(argv, [binary, "--resume", "abc-123-uuid", "-m", "gemini-3-flash"])
    }

    func test_trustWorkspace_emitsSkipTrustBeforeModel() {
        let argv = GeminiArgvBuilder.argv(
            geminiBinary: binary,
            model: "gemini-3-flash",
            trustWorkspace: true
        )
        XCTAssertEqual(argv, [binary, "--skip-trust", "-m", "gemini-3-flash"])
    }

    /// No flags → just the binary path.
    func test_emptyInvocation_returnsBinaryOnly() {
        let argv = GeminiArgvBuilder.argv(geminiBinary: binary)
        XCTAssertEqual(argv, [binary])
    }

    /// `extraArgs` trail in caller-provided order. Used by Sessions v2
    /// when the daemon needs to pin a worktree or pass `--quiet`.
    func test_extraArgs_appendInOrder() {
        let argv = GeminiArgvBuilder.argv(
            geminiBinary: binary,
            model: "gemini-3.1-pro-low",
            extraArgs: ["--quiet", "--dir", "/path/to/repo"]
        )
        XCTAssertEqual(argv, [binary, "-m", "gemini-3.1-pro-low", "--quiet", "--dir", "/path/to/repo"])
    }
}
