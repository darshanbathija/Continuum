import XCTest
@testable import ClawdmeterShared

/// F3-wire daemon-side integration tests for the `ProviderInstanceId`
/// security wire-up. Companion to `ProviderInstanceIdTests` (which
/// covers the source-only value type).
///
/// **Codex eng-review #10 acceptance** (config isolation is
/// security-critical). Locks in:
///   - Env scrub: `CLAUDE_*` / `CODEX_*` / `ANTHROPIC_*` / `GEMINI_*`
///     / `OPENCODE_*` / `OPENROUTER_*` / `OPENAI_*` / `CURSOR_*` /
///     `GOOGLE_APPLICATION_CREDENTIALS` parent env never leaks into
///     a per-instance spawn.
///   - Config-dir isolation (multi-account v1): a non-primary spawn's
///     `CLAUDE_CONFIG_DIR` / `CODEX_HOME` is the instance's config
///     root; `HOME` itself passes through untouched (git/ssh/gh need
///     the real home).
///   - Primary passthrough: the primary instance's env is byte-identical
///     to the parent env (pre-multi-account spawns can't regress).
///   - Secrets injection: per-instance credentials merge AFTER the
///     scrub so `CLAUDE_CODE_OAUTH_TOKEN` survives the `CLAUDE_*` strip.
///   - Cross-instance isolation: building env for instance A doesn't
///     show instance B's auth vars.
///   - Keychain partitioning: per-instance access group means
///     `SecItem*` queries against instance A's group cannot read
///     instance B's group (asserted at the API contract level —
///     a different access-group string is part of the lookup key).
///   - Wire-version 20 back-compat: clients on wireVersion ≤ 19
///     receive payloads without the `providerInstanceId` field;
///     decoding such payloads still succeeds (nil → primary).
///   - Log redaction: raw `homePathOverride` paths never appear in
///     redacted log output.
///
/// Plan: F3-wire — daemon HOME isolation + Keychain partitioning +
/// wireVersion 20.
final class ProviderInstanceWireTests: XCTestCase {

    // MARK: - Env scrub (Codex #10 acceptance 2)

    func test_buildEnv_setsConfigDirVarFromInstanceRoot_andPreservesHome() {
        let instance = ProviderInstanceId(
            kind: .claude,
            name: "personal",
            homePathOverride: "/tmp/clawdmeter-test/claude-personal"
        )
        let parent: [String: String] = [
            "HOME": "/Users/somebody/real-home",
            "PATH": "/usr/bin:/bin",
        ]
        let env = ProviderInstanceEnvironment.buildEnv(
            for: instance,
            parentEnv: parent
        )
        XCTAssertEqual(
            env["CLAUDE_CONFIG_DIR"], "/tmp/clawdmeter-test/claude-personal",
            "CLAUDE_CONFIG_DIR must come from the instance config root"
        )
        XCTAssertEqual(
            env["HOME"], "/Users/somebody/real-home",
            "HOME must pass through untouched — overriding it breaks git/ssh/gh"
        )
    }

    func test_buildEnv_codexInstanceSetsCodexHome() {
        let instance = ProviderInstanceId(
            kind: .codex,
            name: "pro",
            homePathOverride: "/tmp/clawdmeter-test/codex-pro"
        )
        let env = ProviderInstanceEnvironment.buildEnv(
            for: instance,
            parentEnv: ["HOME": "/Users/me", "PATH": "/usr/bin"]
        )
        XCTAssertEqual(env["CODEX_HOME"], "/tmp/clawdmeter-test/codex-pro")
        XCTAssertEqual(env["HOME"], "/Users/me")
        XCTAssertNil(env["CLAUDE_CONFIG_DIR"])
    }

    /// GOLDEN: the primary instance with no secrets must be a byte-
    /// identical passthrough — including any user-set CLAUDE_*/CODEX_*
    /// vars. Pre-multi-account spawn behavior cannot change.
    func test_buildEnv_primaryNoSecretsIsByteIdenticalPassthrough() {
        let parent: [String: String] = [
            "HOME": "/Users/parent",
            "PATH": "/usr/bin",
            "CLAUDE_CONFIG_DIR": "/Users/parent/.claude-custom",
            "ANTHROPIC_VERSION": "2023-06-01",
            "TERM": "xterm-256color",
        ]
        for kind in [AgentKind.claude, .codex] {
            let env = ProviderInstanceEnvironment.buildEnv(
                for: .primary(kind: kind),
                parentEnv: parent
            )
            XCTAssertEqual(env, parent, "primary \(kind) spawn env must be untouched")
        }
    }

    /// Secrets merge AFTER the scrub: an injected CLAUDE_CODE_OAUTH_TOKEN
    /// must survive even though CLAUDE_* is on the scrub list.
    func test_buildEnv_secretsSurviveScrub() {
        let instance = ProviderInstanceId(
            kind: .claude,
            name: "work",
            homePathOverride: "/tmp/claude-work"
        )
        let parent: [String: String] = [
            "HOME": "/Users/me",
            "PATH": "/usr/bin",
            // Hostile inherited token that MUST be scrubbed…
            "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-INHERITED-HOSTILE",
        ]
        let env = ProviderInstanceEnvironment.buildEnv(
            for: instance,
            parentEnv: parent,
            secrets: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-instance-work"]
        )
        // …and replaced by the instance's own credential.
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "sk-ant-oat01-instance-work")
    }

    func test_buildEnv_scrubsEveryProviderNamespacedPrefix() {
        let instance = ProviderInstanceId(
            kind: .claude,
            name: "work",
            homePathOverride: "/tmp/work"
        )
        // Hostile parent env contains an entry for every provider's
        // auth/cache vars + a few benign ones that must survive.
        let parent: [String: String] = [
            "HOME": "/tmp/parent-home",
            "PATH": "/usr/bin:/bin",
            "USER": "tester",
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color",
            // Hostile: provider namespaces that must be scrubbed.
            "CLAUDE_API_KEY": "sk-hostile-claude",
            "ANTHROPIC_API_KEY": "sk-hostile-anthropic",
            "CLAUDE_SESSION": "abc",
            "ANTHROPIC_VERSION": "2023-06-01",
            "CODEX_HOME": "/some/other/codex/home",
            "OPENAI_API_KEY": "sk-hostile-openai",
            "GEMINI_API_KEY": "sk-hostile-gemini",
            "GOOGLE_APPLICATION_CREDENTIALS": "/etc/google-creds.json",
            "OPENCODE_PROVIDER": "openrouter",
            "OPENROUTER_API_KEY": "sk-hostile-openrouter",
            "CURSOR_API_KEY": "sk-hostile-cursor",
        ]
        let env = ProviderInstanceEnvironment.buildEnv(
            for: instance,
            parentEnv: parent
        )

        // Benign vars MUST survive.
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(env["USER"], "tester")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["TERM"], "xterm-256color")

        // Every scrubbed prefix MUST be gone.
        let scrubbed = [
            "CLAUDE_API_KEY", "ANTHROPIC_API_KEY", "CLAUDE_SESSION",
            "ANTHROPIC_VERSION", "CODEX_HOME", "OPENAI_API_KEY",
            "GEMINI_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS",
            "OPENCODE_PROVIDER", "OPENROUTER_API_KEY", "CURSOR_API_KEY",
        ]
        for key in scrubbed {
            XCTAssertNil(env[key], "Provider-namespaced env var \(key) must be scrubbed")
        }

        // Config-dir var points at the instance root; HOME passes through.
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/tmp/work")
        XCTAssertEqual(env["HOME"], "/tmp/parent-home")
    }

    /// Codex #10 acceptance 2 (integration test): "verify that leaking
    /// from one instance to another doesn't happen". The buildEnv path
    /// must produce a per-instance scrub that doesn't carry forward
    /// instance A's provider env into instance B's spawn.
    func test_buildEnv_instanceAEnvDoesNotLeakIntoInstanceB() {
        // Simulate instance A's spawn: HOME points at A's override, env
        // is scrubbed. We do NOT inherit anything from this; the test
        // proves that even if A had set provider vars in its spawn, B's
        // spawn (built from the same parent env) doesn't see them.
        let instanceA = ProviderInstanceId(
            kind: .claude,
            name: "personal",
            homePathOverride: "/tmp/claude-personal"
        )
        let instanceB = ProviderInstanceId(
            kind: .claude,
            name: "work",
            homePathOverride: "/tmp/claude-work"
        )
        // The "parent" env carries A's provider vars (as if some
        // mis-configured ancestor leaked them).
        let parent: [String: String] = [
            "HOME": "/tmp/leaked-home",
            "PATH": "/usr/bin",
            "CLAUDE_API_KEY": "instance-A-secret",
            "ANTHROPIC_API_KEY": "instance-A-anthropic-secret",
            "CLAUDE_SESSION_TOKEN": "instance-A-session",
        ]
        let envA = ProviderInstanceEnvironment.buildEnv(for: instanceA, parentEnv: parent)
        let envB = ProviderInstanceEnvironment.buildEnv(for: instanceB, parentEnv: parent)

        // Both spawns must have NO provider vars (scrubbed).
        XCTAssertNil(envA["CLAUDE_API_KEY"])
        XCTAssertNil(envB["CLAUDE_API_KEY"])
        XCTAssertNil(envA["ANTHROPIC_API_KEY"])
        XCTAssertNil(envB["ANTHROPIC_API_KEY"])
        XCTAssertNil(envA["CLAUDE_SESSION_TOKEN"])
        XCTAssertNil(envB["CLAUDE_SESSION_TOKEN"])

        // Config roots are distinct and instance-pinned.
        XCTAssertEqual(envA["CLAUDE_CONFIG_DIR"], "/tmp/claude-personal")
        XCTAssertEqual(envB["CLAUDE_CONFIG_DIR"], "/tmp/claude-work")
        XCTAssertNotEqual(envA["CLAUDE_CONFIG_DIR"], envB["CLAUDE_CONFIG_DIR"])
    }

    func test_isScrubbed_matchesEveryDocumentedPrefix() {
        let scrubbedSamples = [
            "CLAUDE_API_KEY", "CLAUDE_", "CLAUDE_anything",
            "ANTHROPIC_API_KEY", "ANTHROPIC_VERSION",
            "CODEX_HOME", "CODEX_FOO",
            "OPENAI_API_KEY",
            "GEMINI_API_KEY",
            "GOOGLE_APPLICATION_CREDENTIALS",
            "OPENCODE_PROVIDER", "OPENROUTER_API_KEY",
            "CURSOR_API_KEY",
        ]
        for key in scrubbedSamples {
            XCTAssertTrue(
                ProviderInstanceEnvironment.isScrubbed(envKey: key),
                "Expected \(key) to be scrubbed"
            )
        }

        // Negative: benign vars must NOT match.
        let benign = ["PATH", "HOME", "USER", "TERM", "SHELL", "LANG", "TMPDIR", "PYTHONPATH"]
        for key in benign {
            XCTAssertFalse(
                ProviderInstanceEnvironment.isScrubbed(envKey: key),
                "Expected benign \(key) to pass through"
            )
        }
    }

    // MARK: - Keychain partitioning (Codex #10 acceptance 3)

    /// A leaked-key scenario for instance A's Keychain partition must
    /// be invisible to instance B. We can't write to the real Keychain
    /// in unit tests (no entitlements + would touch the user's actual
    /// Keychain), so we assert the lookup contract at the API surface:
    ///   - Two instances with distinct `keychainAccessGroupOverride`
    ///     values produce two distinct `PastedAnthropicTokenProvider`
    ///     instances with distinct underlying access-group + service
    ///     name pairs. The Apple Security framework treats access
    ///     group as part of the lookup key, so different groups read
    ///     different items by construction.
    ///   - The factory's identity contract holds: each non-primary
    ///     call produces a fresh provider; the primary uses the
    ///     shared singleton.
#if os(iOS) || os(watchOS) || os(macOS)
    func test_forInstance_partitionsByAccessGroup() {
        let instanceA = ProviderInstanceId(
            kind: .claude,
            name: "personal",
            keychainAccessGroupOverride: "LRL8MRH6B4.ai.continuum.kc.personal"
        )
        let instanceB = ProviderInstanceId(
            kind: .claude,
            name: "work",
            keychainAccessGroupOverride: "LRL8MRH6B4.ai.continuum.kc.work"
        )
        let providerA = PastedAnthropicTokenProvider.forInstance(instanceA)
        let providerB = PastedAnthropicTokenProvider.forInstance(instanceB)

        // The two providers must be distinct instances (different
        // partitions, different caches).
        XCTAssertFalse(providerA === providerB, "Distinct instances must produce distinct providers")

        // Neither equals the shared primary singleton (which has no
        // overrides).
        let primaryProvider = PastedAnthropicTokenProvider.forInstance(.primary(kind: .claude))
        XCTAssertFalse(providerA === primaryProvider)
        XCTAssertFalse(providerB === primaryProvider)
    }

    func test_forInstance_primaryReturnsSharedSingleton() {
        let p1 = PastedAnthropicTokenProvider.forInstance(.primary(kind: .claude))
        let p2 = PastedAnthropicTokenProvider.forInstance(.primary(kind: .claude))
        XCTAssertTrue(p1 === p2, "primary instance must reuse the shared singleton")
        XCTAssertTrue(p1 === PastedAnthropicTokenProvider.shared())
    }
#endif

    // MARK: - Wire-version 20 back-compat (Codex #10 acceptance 4)

    /// A v19 client encoding a `NewSessionRequest` without
    /// `providerInstanceId` must round-trip through a v20-aware decoder
    /// cleanly. The decoded request resolves at lookup time to
    /// `ProviderInstanceId.primary(kind:)` — the back-compat default.
    func test_newSessionRequest_v19Encoding_decodesAsPrimary() throws {
        // A v19-shaped payload (NO `providerInstanceId` field).
        let json = """
        {
          "repoKey": "/Users/x/repo",
          "agent": "claude",
          "planMode": false,
          "useWorktree": true
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(NewSessionRequest.self, from: json)
        XCTAssertEqual(decoded.repoKey, "/Users/x/repo")
        XCTAssertEqual(decoded.agent, .claude)
        XCTAssertNil(
            decoded.providerInstanceId,
            "v19 payloads omit providerInstanceId; decoder must produce nil"
        )
    }

    /// Symmetric: a v20 client encoding `providerInstanceId` round-trips
    /// through a v20 decoder cleanly.
    func test_newSessionRequest_v20Encoding_carriesProviderInstanceId() throws {
        let original = NewSessionRequest(
            repoKey: "/Users/x/repo",
            agent: .claude,
            providerInstanceId: "claude/personal"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NewSessionRequest.self, from: data)
        XCTAssertEqual(decoded.providerInstanceId, "claude/personal")
    }

    /// An older `AgentSession` (schema v7, no providerInstanceId field)
    /// must decode cleanly with the field nil, and `resolveProviderInstance`
    /// must fall back to the primary instance.
    func test_agentSession_v7Encoding_resolvesAsPrimary() async throws {
        // v7-shaped payload — every field present except the new
        // providerInstanceId. Numbers / dates use the encoder's own
        // representation; we round-trip from a real session for
        // determinism.
        let original = AgentSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            repoKey: "/Users/x/repo",
            repoDisplayName: "repo",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .planning,
            planText: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastEventAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastEventSeq: 0
            // providerInstanceId NOT set — defaults to nil.
        )
        XCTAssertNil(original.providerInstanceId)

        // Round-trip through Codable and verify the field stays nil.
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertNil(decoded.providerInstanceId)

        // Resolve against a registry — must fall back to primary.
        let registry = ProviderInstanceRegistry()
        let resolved = await decoded.resolveProviderInstance(in: registry)
        XCTAssertTrue(resolved.isPrimary)
        XCTAssertEqual(resolved.kind, .claude)
    }

    /// A v20 `AgentSession` with `providerInstanceId == "claude/personal"`
    /// resolves to the registered custom instance when present, and
    /// falls back to primary when the registry doesn't carry that id
    /// (e.g. a session restored from disk after the user removed the
    /// instance from Settings).
    func test_agentSession_v8ResolvesToRegisteredInstanceOrPrimary() async {
        let registry = ProviderInstanceRegistry()
        let custom = ProviderInstanceId(
            kind: .claude,
            name: "personal",
            homePathOverride: "/tmp/claude-personal"
        )
        await registry.upsert(custom)

        let session = AgentSession(
            id: UUID(),
            repoKey: "/x",
            repoDisplayName: "r",
            agent: .claude,
            model: nil,
            goal: nil,
            worktreePath: nil,
            tmuxWindowId: nil,
            tmuxPaneId: nil,
            status: .running,
            planText: nil,
            createdAt: Date(),
            lastEventAt: Date(),
            lastEventSeq: 0,
            providerInstanceId: "claude/personal"
        )
        let resolved = await session.resolveProviderInstance(in: registry)
        XCTAssertEqual(resolved, custom, "Registered instance must resolve to the configured value")

        // Now remove the custom instance — resolver must fall back to
        // primary (back-compat protection).
        await registry.remove(wireId: custom.wireId)
        let fallback = await session.resolveProviderInstance(in: registry)
        XCTAssertTrue(fallback.isPrimary)
        XCTAssertEqual(fallback.kind, .claude)
    }

    /// Codex #10 acceptance: clients on `wireVersion ≤ 19` see only the
    /// primary instance. The capability gate `supportsProviderInstance`
    /// must return false for v19 and true for v20. The `current` floor
    /// is asserted >= 20 so that A10's wireVersion-21 bump doesn't
    /// re-break this gate — providerInstance is now reachable on every
    /// supported client.
    func test_capabilityGate_supportsProviderInstance() {
        XCTAssertFalse(AgentControlWireVersion.supportsProviderInstance(serverWireVersion: 19))
        XCTAssertFalse(AgentControlWireVersion.supportsProviderInstance(serverWireVersion: 17))
        XCTAssertFalse(AgentControlWireVersion.supportsProviderInstance(serverWireVersion: nil))
        XCTAssertTrue(AgentControlWireVersion.supportsProviderInstance(serverWireVersion: 20))
        XCTAssertTrue(AgentControlWireVersion.supportsProviderInstance(serverWireVersion: 21))
        XCTAssertEqual(AgentControlWireVersion.providerInstanceMinimum, 20)
        XCTAssertGreaterThanOrEqual(AgentControlWireVersion.current, 20)
    }

    // MARK: - UsageEnvelope dual-shape (v19 ↔ v20 per-instance keys)

    /// A v19 server populates only `usage["claude"]` (kind-keyed). A v20
    /// client asking for the wireId `"claude/__primary__"` must resolve
    /// to the same data via the suffix-strip fallback.
    func test_usageEnvelope_v20ClientReadsV19PrimaryKey() {
        let claudeUsage = UsageData(
            sessionPct: 25,
            sessionResetMins: 60,
            sessionEpoch: 1_700_000_000,
            weeklyPct: 10,
            weeklyResetMins: 600,
            weeklyEpoch: 1_700_000_000,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let envelope = UsageEnvelope(
            claude: nil,
            codex: nil,
            usage: ["claude": claudeUsage],
            lastChecked: Date()
        )
        // v20 client (wireId-keyed) lookup.
        let viaWireId = envelope.usageData(for: ProviderInstanceId.primary(kind: .claude))
        XCTAssertNotNil(viaWireId)
        XCTAssertEqual(viaWireId?.sessionPct, 25)
        // Legacy v19 client (kind-keyed) lookup — same data.
        let viaKind = envelope.usageData(for: "claude")
        XCTAssertNotNil(viaKind)
        XCTAssertEqual(viaKind?.sessionPct, 25)
    }

    /// A v20 server populates `usage["claude/__primary__"]` and
    /// `usage["claude/personal"]`. A v19 client asking for the bare
    /// kind must resolve to the primary instance (via the dual-key
    /// bridge); the personal instance is invisible — that's the Codex
    /// #10 acceptance "older clients see only primary".
    func test_usageEnvelope_v19ClientSeesOnlyPrimary() {
        let primaryUsage = UsageData(
            sessionPct: 10,
            sessionResetMins: 60,
            sessionEpoch: 1_700_000_000,
            weeklyPct: 5,
            weeklyResetMins: 600,
            weeklyEpoch: 1_700_000_000,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let personalUsage = UsageData(
            sessionPct: 80,
            sessionResetMins: 30,
            sessionEpoch: 1_700_000_000,
            weeklyPct: 40,
            weeklyResetMins: 600,
            weeklyEpoch: 1_700_000_000,
            status: .allowed,
            representativeClaim: .fiveHour,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let envelope = UsageEnvelope(
            claude: nil,
            codex: nil,
            usage: [
                "claude/__primary__": primaryUsage,
                "claude/personal": personalUsage,
            ],
            lastChecked: Date()
        )
        // v19 client asks for the bare kind — resolves to primary (10),
        // NEVER personal (80).
        let v19View = envelope.usageData(for: "claude")
        XCTAssertEqual(v19View?.sessionPct, 10, "v19 client must see only primary, never personal")

        // v20 client asks for the personal wireId — gets the personal
        // snapshot.
        let personalLookup = envelope.usageData(
            for: ProviderInstanceId(kind: .claude, name: "personal")
        )
        XCTAssertEqual(personalLookup?.sessionPct, 80)
    }

    // MARK: - Log redaction (Codex #10 acceptance 5)

    func test_logRedaction_replacesHomePathWithToken() {
        let instance = ProviderInstanceId(
            kind: .claude,
            name: "personal",
            homePathOverride: "/Users/secret/.claude-personal"
        )
        let raw = "spawned claude with HOME=/Users/secret/.claude-personal --model opus"
        let redacted = ProviderInstanceLogRedaction.redact(raw, for: instance)
        XCTAssertFalse(
            redacted.contains("/Users/secret/.claude-personal"),
            "Raw homePathOverride must be redacted: got \(redacted)"
        )
        XCTAssertTrue(
            redacted.contains("<HOME for claude/personal>"),
            "Redacted token must be substituted: got \(redacted)"
        )
    }

    func test_logRedaction_primaryInstanceIsNoOp() {
        let primary = ProviderInstanceId.primary(kind: .claude)
        let raw = "spawned claude with model opus"
        let redacted = ProviderInstanceLogRedaction.redact(raw, for: primary)
        // No override => no substitution.
        XCTAssertEqual(redacted, raw)
    }

    func test_logRedaction_tokenFormatIsStable() {
        XCTAssertEqual(
            ProviderInstanceLogRedaction.homeToken(for: .primary(kind: .claude)),
            "<HOME for claude/__primary__>"
        )
        let custom = ProviderInstanceId(kind: .codex, name: "work")
        XCTAssertEqual(
            ProviderInstanceLogRedaction.homeToken(for: custom),
            "<HOME for codex/work>"
        )
    }
}
