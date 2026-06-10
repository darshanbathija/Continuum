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

    override func tearDown() {
        // The resolver is process-global; restore the unattached default
        // so later test classes don't inherit this suite's registry.
        InstanceSpawnEnv.detachForTesting()
        super.tearDown()
    }

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
        InstanceSpawnEnv.setClaudeTokenLookupForTesting { _ in "sk-ant-oat01-test" }

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
        InstanceSpawnEnv.setClaudeTokenLookupForTesting { _ in "sk-ant-oat01-test" }

        // A claude-registered wireId pinned onto a codex session is a
        // client bug — refuse rather than spawn codex with claude's env.
        let crossKind = await InstanceSpawnEnv.isSpawnable(wireId: "claude/work", agent: .codex)
        XCTAssertFalse(crossKind)
    }

    /// A registered secondary that CANNOT be config-isolated (empty
    /// config root, or a kind with no config-dir var) must fail closed —
    /// the scrub-without-isolation fallthrough would spawn against the
    /// PRIMARY account's real config under a "work" label. Only
    /// reachable via a hand-edited provider-instances.json.
    func testResolverFailsClosedOnNonIsolatableSecondaries() async {
        let registry = ProviderInstanceRegistry()
        // Empty config root (record round-trip of configRoot "").
        await registry.upsert(ProviderInstanceId(kind: .claude, name: "rootless"))
        // Kind with no config-dir var.
        await registry.upsert(ProviderInstanceId(kind: .gemini, name: "work", homePathOverride: "/tmp/g"))
        InstanceSpawnEnv.attach(registry)
        InstanceSpawnEnv.setClaudeTokenLookupForTesting { _ in "sk-ant-oat01-test" }

        let rootless = await InstanceSpawnEnv.isSpawnable(wireId: "claude/rootless", agent: .claude)
        XCTAssertFalse(rootless, "secondary with no config root must refuse, not spawn against primary config")
        let unisolatable = await InstanceSpawnEnv.isSpawnable(wireId: "gemini/work", agent: .gemini)
        XCTAssertFalse(unisolatable, "kinds without a config-dir var can't host secondaries")
    }

    /// Red-team fix: a Claude secondary whose Keychain token is missing
    /// (expired, cleared, never captured) must fail closed. A token-less
    /// spawn under CLAUDE_CONFIG_DIR falls back to the PRIMARY's per-user
    /// Keychain login — the wrong subscription billed under a "work" label.
    func testResolverFailsClosedWhenClaudeSecondaryHasNoToken() async {
        let registry = ProviderInstanceRegistry()
        let work = ProviderInstanceId(kind: .claude, name: "work", homePathOverride: "/tmp/w")
        await registry.upsert(work)
        InstanceSpawnEnv.attach(registry)
        InstanceSpawnEnv.setClaudeTokenLookupForTesting { _ in nil }

        let spawnable = await InstanceSpawnEnv.isSpawnable(wireId: "claude/work", agent: .claude)
        XCTAssertFalse(spawnable, "token-less claude secondary must refuse, not bill the primary")

        // With a token it resolves and carries the credential.
        InstanceSpawnEnv.setClaudeTokenLookupForTesting { _ in "sk-ant-oat01-work" }
        guard case .resolved(_, let secrets) = await InstanceSpawnEnv.resolve(wireId: "claude/work", agent: .claude) else {
            return XCTFail("token-bearing secondary must resolve")
        }
        XCTAssertEqual(secrets["CLAUDE_CODE_OAUTH_TOKEN"], "sk-ant-oat01-work")
    }

    /// Unattached resolver (tests, pre-boot): nil/primary pins resolve;
    /// secondary pins fail closed — no registry can vouch for them.
    func testUnattachedResolverFailsClosedOnSecondaries() async {
        InstanceSpawnEnv.detachForTesting()
        let nilOk = await InstanceSpawnEnv.isSpawnable(wireId: nil, agent: .claude)
        XCTAssertTrue(nilOk)
        let secondary = await InstanceSpawnEnv.isSpawnable(wireId: "claude/work", agent: .claude)
        XCTAssertFalse(secondary)
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
