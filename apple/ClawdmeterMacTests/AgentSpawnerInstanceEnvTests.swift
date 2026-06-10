import XCTest
@testable import Clawdmeter
import ClawdmeterShared

/// Multi-account Phase 4: the Claude PTY spawn env with a pinned
/// provider instance, plus the daemon-side `InstanceSpawnEnv` resolver.
///
/// Locks in:
///   - GOLDEN: primary instance + no secrets is byte-identical to the
///     pre-multi-account `claudePtyEnv()` (the 5-call-site hot zone).
///   - A pinned instance gets `CLAUDE_CONFIG_DIR` + the per-instance
///     `CLAUDE_CODE_OAUTH_TOKEN`, while the billing rail
///     (`ANTHROPIC_API_KEY` strip) still holds.
///   - Credential bleed: instance A's secret never reaches instance B.
///   - Resolver fail-closed: unknown wireIds refuse to spawn (nil), and
///     kind mismatches refuse too — never a silent primary fallback.
@MainActor
final class AgentSpawnerInstanceEnvTests: XCTestCase {

    func testPrimaryNoSecretsIsByteIdenticalToLegacyEnv() {
        let legacy = AgentSpawner.claudePtyEnv(extra: ["FOO": "bar"])
        let viaInstance = AgentSpawner.claudePtyEnv(
            extra: ["FOO": "bar"],
            instance: .primary(kind: .claude),
            secrets: [:]
        )
        XCTAssertEqual(viaInstance, legacy)
    }

    func testInstanceEnvCarriesConfigDirAndTokenAndKeepsBillingRail() {
        let instance = ProviderInstanceId(
            kind: .claude, name: "work", homePathOverride: "/tmp/claude-work"
        )
        let env = AgentSpawner.claudePtyEnv(
            extra: ["ANTHROPIC_API_KEY": "sk-from-repo-env"],
            instance: instance,
            secrets: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-work"]
        )
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/tmp/claude-work")
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "sk-ant-oat01-work")
        // Billing rail: API credentials never reach a claude spawn.
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        // Real HOME preserved (worktrees need git/ssh/gh).
        XCTAssertEqual(env["HOME"], ProcessInfo.processInfo.environment["HOME"])
    }

    func testCredentialBleedAcrossInstances() {
        let a = ProviderInstanceId(kind: .claude, name: "a", homePathOverride: "/tmp/a")
        let b = ProviderInstanceId(kind: .claude, name: "b", homePathOverride: "/tmp/b")
        let envA = AgentSpawner.claudePtyEnv(instance: a, secrets: ["CLAUDE_CODE_OAUTH_TOKEN": "token-A"])
        let envB = AgentSpawner.claudePtyEnv(instance: b, secrets: [:])
        XCTAssertEqual(envA["CLAUDE_CODE_OAUTH_TOKEN"], "token-A")
        XCTAssertNil(envB["CLAUDE_CODE_OAUTH_TOKEN"], "instance B must never see instance A's token")
        XCTAssertEqual(envB["CLAUDE_CONFIG_DIR"], "/tmp/b")
    }

    // MARK: - InstanceSpawnEnv resolver

    func testResolverFailsClosedOnUnknownWireId() async {
        let registry = ProviderInstanceRegistry()
        InstanceSpawnEnv.attach(registry)

        let spawnable = await InstanceSpawnEnv.isSpawnable(wireId: "claude/ghost", agent: .claude)
        XCTAssertFalse(spawnable, "unknown pins must refuse, not fall back to primary")

        if case .resolved = await InstanceSpawnEnv.resolve(wireId: "claude/ghost", agent: .claude) {
            XCTFail("unknown wireId must resolve to .unknown")
        }
    }

    func testResolverAcceptsNilAndPrimaryAndRegistered() async {
        let registry = ProviderInstanceRegistry()
        let work = ProviderInstanceId(kind: .claude, name: "work", homePathOverride: "/tmp/w")
        await registry.upsert(work)
        InstanceSpawnEnv.attach(registry)

        let nilOk = await InstanceSpawnEnv.isSpawnable(wireId: nil, agent: .claude)
        XCTAssertTrue(nilOk)
        let primaryOk = await InstanceSpawnEnv.isSpawnable(wireId: "claude/__primary__", agent: .claude)
        XCTAssertTrue(primaryOk)
        let registeredOk = await InstanceSpawnEnv.isSpawnable(wireId: "claude/work", agent: .claude)
        XCTAssertTrue(registeredOk)

        guard case .resolved(let instance, _) = await InstanceSpawnEnv.resolve(wireId: "claude/work", agent: .claude) else {
            return XCTFail("registered wireId must resolve")
        }
        XCTAssertEqual(instance, work)
    }

    func testResolverRejectsKindMismatch() async {
        let registry = ProviderInstanceRegistry()
        await registry.upsert(ProviderInstanceId(kind: .claude, name: "work", homePathOverride: "/tmp/w"))
        InstanceSpawnEnv.attach(registry)

        // A claude-registered wireId pinned onto a codex session is a
        // client bug — refuse rather than spawn codex with claude's env.
        let crossKind = await InstanceSpawnEnv.isSpawnable(wireId: "claude/work", agent: .codex)
        XCTAssertFalse(crossKind)
    }

    func testHarnessEnvOverlaysCodexHomeAndPassesPrimaryThrough() async {
        let registry = ProviderInstanceRegistry()
        let pro = ProviderInstanceId(kind: .codex, name: "pro", homePathOverride: "/tmp/codex-pro")
        await registry.upsert(pro)
        InstanceSpawnEnv.attach(registry)

        let base = ["PATH": "/usr/bin", "HOME": "/Users/me"]
        let overlaid = await InstanceSpawnEnv.harnessEnv(base: base, wireId: "codex/pro", agent: .codex)
        XCTAssertEqual(overlaid?["CODEX_HOME"], "/tmp/codex-pro")
        XCTAssertEqual(overlaid?["HOME"], "/Users/me")

        let primary = await InstanceSpawnEnv.harnessEnv(base: base, wireId: nil, agent: .codex)
        XCTAssertEqual(primary, base, "primary harness env must pass through unchanged")

        let unknown = await InstanceSpawnEnv.harnessEnv(base: base, wireId: "codex/ghost", agent: .codex)
        XCTAssertNil(unknown)
    }
}
