import Foundation

// AgentControl wire-version gates. Keep this file focused on the current
// constants and feature predicates; detailed historical bump notes live in
// docs/protocol-wire-version-history.md.

// MARK: - Wire version (Sessions v2 E8)

/// Single source of truth for the wire-protocol revision. Bumped in lockstep
/// with breaking shape changes. v3 adds: `effort`, `abPairSessionId`,
/// `abPairDecidedAt`, `abPairWinnerSessionId` on `AgentSession`; `ReasoningEffort` + `ModelCatalog`
/// + mid-session change endpoints + `WireChatSnapshot` + `HealthResponse`.
///
/// iOS reads this on pair-test or session-list refresh and compares to its
/// own constant. Mismatch surfaces a banner. New endpoints return HTTP 426.
public enum AgentControlWireVersion {
    /// Current wire version. Bump when adding a new WS op, REST endpoint, or
    /// DTO that older peers must explicitly gate. Historical bump notes live
    /// in docs/protocol-wire-version-history.md.
    public static let current: Int = 27
    /// Minimum wire version that exposes `AgentKind.opencode` natively.
    /// Clients with `serverWireVersion < this` decode opencode sessions
    /// as `.unknown` (X3 fallback) and render as "Other agent". This is
    /// the gate the Mac uses to suppress OpenCode-related controls when
    /// the paired iPhone is too old to render them correctly.
    public static let opencodeMinimum: Int = 13
    /// Minimum wire version that exposes `AgentKind.cursor` natively.
    /// Clients below this version decode Cursor sessions as `.unknown`.
    public static let cursorMinimum: Int = 17
    /// Minimum wire version that supports the `compose-draft` WS op.
    /// iOS guards `postComposeDraft` on this — older Macs would reject
    /// the unknown op via `.unsupportedData` close (review §10 finding).
    public static let composeDraftMinimum: Int = 4
    /// Minimum wire version that supports the `chat-subscribe` WS op
    /// (Phase 2 push-based chat snapshot delivery, replacing iOS 3s HTTP
    /// polling). iOS guards WS subscribe on this — older Macs stay on
    /// the `/chat-snapshot` HTTP polling path.
    public static let chatSubscribeMinimum: Int = 5
    /// Minimum wire version that exposes `AgentKind.gemini` + the
    /// `usage` dict shape on `/usage`. iOS hides Gemini UI when
    /// `serverWireVersion < this` and surfaces an "Update Clawdmeter on
    /// Mac" banner instead of dropping into a confused state.
    public static let geminiMinimum: Int = 6

    /// Minimum wire version that supports the Antigravity Plan endpoint
    /// + WS subscribe op (v7 — Antigravity 2 native release). iOS hides
    /// the Plan tab when `serverWireVersion < this` and shows
    /// "Update Clawdmeter on Mac for the Plan tab" copy instead.
    public static let antigravityMinimum: Int = 7

    /// Minimum wire version that surfaces the Codex SDK mode toggle
    /// state via `UsageData.codexSDKModeActive` (v8). Older Macs paired
    /// with a v8 iOS hide the "· SDK mode" subtitle and assume Disk
    /// mode by default.
    public static let codexSDKMinimum: Int = 8

    /// Minimum wire version that supports the Chat tab endpoints
    /// (`POST /chat-sessions`, `GET /chat-providers`, schema v5 fields).
    /// iOS hides the Chat tab when `serverWireVersion < this`.
    public static let chatMinimum: Int = 9

    /// Minimum wire version that supports Frontier compare endpoints
    /// (`POST /chat-sessions/frontier/*`, `frontier-subscribe` WS op).
    /// Daemon endpoints ship in v0.8 for forward-compat; the Mac/iOS UI
    /// lands in v0.9 alongside the Antigravity (agy) replacement for
    /// gemini CLI.
    public static let frontierMinimum: Int = 9

    /// Minimum wire version that supports the per-session Codex chat
    /// backend choice (`AgentSession.codexChatBackend`). Older Macs
    /// ignore the per-request override.
    public static let codexChatBackendMinimum: Int = 9

    /// Minimum wire version that supports spawning Gemini sessions via
    /// Antigravity 2's `agentapi` HTTP-RPC (v10). Older Macs can't host
    /// these sessions — iOS hides the agentapi spawn path and surfaces
    /// "Update Clawdmeter on Mac" copy. v0.42 quota fallback (D9) still
    /// works on older Macs because quota is a separate, read-only path.
    public static let agentapiMinimum: Int = 10

    /// Minimum wire version at which the daemon's chat surface dispatches
    /// Gemini through `agentapi`. v0.8.1 (wire v10) migrated the Mac UI's
    /// spawn path (`SessionsView.spawnAntigravitySession`); v0.9 (wire v11)
    /// adds a daemon-side `handlePostGeminiChatSession` that lifts the v0.8
    /// 501 stub on `POST /chat-sessions {provider: "gemini"}`. iOS gates
    /// the Gemini chat row on this so older Macs (wire v10 or below)
    /// surface a "v0.9 required" CTA instead of letting users try a
    /// POST that returns 501.
    public static let antigravityChatMinimum: Int = 11

    /// Minimum wire version that exposes the per-turn lifecycle field
    /// `WireChatSnapshot.currentTurnState`. Older daemons send snapshots
    /// without the field; lenient decoder defaults to `.idle` so iOS
    /// keeps working but the Stopwatch + Stop→Send transitions
    /// fall back to a heuristic (no new event in 2s = done). Used by
    /// the ChatV2 status strip to detect whether the heuristic
    /// fallback is needed.
    public static let turnLifecycleMinimum: Int = 14

    /// Minimum wire version that honors the `deepResearch` field on
    /// `CreateChatSessionRequest` / `FrontierModelSlot`. Older Macs
    /// decode the field as `false` (decodeIfPresent default) so the
    /// session lands as a regular send. iOS surfaces a warning when
    /// the user enables Deep Research against a too-old paired Mac.
    public static let deepResearchMinimum: Int = 14

    /// Minimum wire version that supports `GET /chat-sessions/search?q=`.
    /// Older Macs 404; clients fall back to grepping the local LRU cache
    /// (which only covers the most-recent 2 conversations on iOS, 20 on
    /// Mac) and label results "Recent only".
    public static let chatSearchMinimum: Int = 14
    /// Minimum wire version that surfaces the Code V2 durable control-plane
    /// fields (`SessionRuntimeBinding`, explicit cwd fields, mobile command
    /// receipts, PR mirror state). Older peers keep using the legacy
    /// AgentSession shape; every new field is decodeIfPresent.
    public static let codeV2Minimum: Int = 15

    /// Minimum wire version that exposes the persisted workspace store at
    /// `GET /workspaces` + `PATCH /workspaces/:id`. Older Macs 404 the
    /// requests; iOS falls back to per-session repo bucketing (no per-repo
    /// defaults inheritance for new sessions).
    public static let workspacesMinimum: Int = 16

    /// Minimum wire version where every write endpoint (send, approve,
    /// interrupt, change-*, autopilot, pick-winner, create-pr, merge)
    /// honors a per-request idempotency key and returns a
    /// `MobileCommandReceipt`. Older Macs treat the field as a no-op;
    /// iOS retains the receipt locally so a duplicate retry against
    /// a too-old Mac surfaces as "no receipt — assume delivered".
    public static let mobileOutboxMinimum: Int = 16
    /// Minimum wire version that exposes Mac-backed Code workbench runtime
    /// endpoints to iOS: run profile start/stop/snapshot and checkpoint
    /// create / restore-preview / restore.
    public static let codeWorkbenchRemoteMinimum: Int = 18
    /// Minimum wire version that exposes the unified lifecycle snapshot
    /// spine (`GET /sessions/:id/lifecycle` + `lifecycle-subscribe` WS).
    public static let lifecycleMinimum: Int = 19

    /// Minimum wire version that exposes durable per-provider defaults.
    public static let providerDefaultsMinimum: Int = 19

    /// Minimum wire version that exposes configured-instance fields
    /// (`ProviderInstanceId.wireId`) on session DTOs + the `UsageEnvelope`
    /// `usage` dict's per-instance keys. F3-wire (2026-05-26).
    ///
    /// Clients on `wireVersion < providerInstanceMinimum` (i.e. ≤ 19)
    /// still receive the legacy single-instance payloads and only ever
    /// see/select the primary instance for each `AgentKind`. The
    /// `providerInstanceId` field is `decodeIfPresent` so a v19 server
    /// reading a v20 client's request also degrades cleanly (the
    /// daemon falls back to `ProviderInstanceId.primary(kind:)`).
    ///
    /// Codex eng-review #10 acceptance: this gate is what guarantees the
    /// security wire-up (HOME isolation, Keychain partitioning, env
    /// scrubbing) never strands a too-old client in a half-configured
    /// multi-instance state.
    public static let providerInstanceMinimum: Int = 20

    /// Minimum wire version that supports the chat shell/detail split on
    /// `chat-subscribe` (A10, 2026-05-27). When the client subscribes with
    /// `wireVersion >= 21`, the daemon pushes a thin `ChatShellEvent`
    /// (~80 bytes — session id, sequence number, kind, emittedAt, optional
    /// token counts) followed by a heavy `ChatDetailEvent` (items, plan
    /// steps, source entries, artifacts, codex todos, token totals) per
    /// commit window. Clients on wireVersion ≤ 20 keep receiving the full
    /// `WireChatSnapshot` JSON frame per commit (the legacy shape).
    ///
    /// The dispatch branch is chosen ONCE per connection from the
    /// `wireVersion` field on the subscribe envelope. The shell event
    /// drives the lightweight activity strip / sidebar summary; the
    /// detail event fills in the full body when it arrives.
    public static let shellDetailMinimum: Int = 21

    /// Minimum wire version that exposes workspace-tab inherited context
    /// metadata on `AgentSession`.
    public static let tabContextMinimum: Int = 22

    /// Minimum wire version that supports the workspace-onboarding routes
    /// (Add-Repo flow). Mac daemons on `< 23` 404 the requests; iOS surfaces
    /// "Update Clawdmeter on the Mac" instead of letting the user fire a
    /// request that will silently drop. Endpoints gated:
    /// `POST /workspaces/open-local`, `/from-github`, `/quick-start`,
    /// `/wake-mac`, `GET /workspaces/allow-list`.
    public static let workspaceOnboardingMinimum: Int = 23

    /// Minimum wire version that supports vendor CLI/MCP provisioning routes:
    /// `GET /vendor-provisioning/vendors`,
    /// `POST /vendor-provisioning/check-device`,
    /// `/vendor-provisioning/vendors/:id/actions`,
    /// `/vendor-provisioning/vendors/:id/env/preview`, and
    /// `/vendor-provisioning/vendors/:id/env/import`.
    public static let vendorProvisioningMinimum: Int = 24
    /// v25: minimum wire version exposing `POST /sessions/:id/revive`
    /// (respawn a degraded session's dead tmux pane). Older Macs 404 the
    /// route; iOS hides the Revive button + shows "Update Clawdmeter on the
    /// Mac" when the paired Mac is below this.
    public static let reviveMinimum: Int = 25

    /// v26: minimum wire version exposing `AgentKind.grok` (native ACP driver).
    /// Older Macs decode `.grok` as `.unknown` ("Other agent") and hide it from
    /// pickers; iOS shows "Update Clawdmeter on the Mac".
    public static let grokMinimum: Int = 26
    /// v26: minimum wire version where the daemon drives ACP sessions
    /// (`.acpGrok`/`.acpCursor`) through the native harness driver.
    public static let acpDriveMinimum: Int = 26

    /// v27: minimum wire version where the daemon's `POST /sessions` accepts
    /// `NewSessionRequest.existingWorkspacePath` (reuse a Mac-provisioned
    /// worktree) + `sessionId` (pre-minted id) for harness Code-tab spawns.
    /// The Mac gates its Code-tab "spawn via daemon harness" fork on this; an
    /// older daemon would ignore the fields and double-provision, so the Mac
    /// falls back to the tmux path below this version.
    public static let harnessSpawnMinimum: Int = 27

    /// Forward-compat client-side check (X3-A). Returns `true` when the
    /// client should flag a mismatch banner. The contract is *forward-
    /// compatible*: newer servers (e.g. wire v7) work fine with this
    /// client; per-feature gates (`supportsGemini`, `supportsChatSubscribe`,
    /// `supportsComposeDraft`) handle the feature surface. Only true when
    /// the server is genuinely too old for the minimum feature floor
    /// (`composeDraftMinimum`).
    ///
    /// - Parameter serverWireVersion: the version the paired Mac reports
    ///   on `/health`. `nil` means we haven't heard from the Mac yet —
    ///   that's not a mismatch.
    /// - Returns: `true` only when `serverWireVersion < composeDraftMinimum`.
    public static func hasMismatch(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v < composeDraftMinimum
    }

    public static func supportsGemini(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= geminiMinimum
    }

    public static func supportsGrok(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= grokMinimum
    }

    public static func supportsACPDrive(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= acpDriveMinimum
    }

    public static func supportsChatSubscribe(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= chatSubscribeMinimum
    }

    public static func supportsComposeDraft(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= composeDraftMinimum
    }

    /// Whether the paired Mac is wire v7+ and therefore exposes
    /// `/sessions/:id/antigravity-plan` + the `antigravity-plan-subscribe`
    /// WS op. Used by iOS to gate the Plan tab visibility.
    public static func supportsAntigravityPlan(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= antigravityMinimum
    }

    /// Whether the paired Mac is wire v8+ and therefore reports the
    /// Codex SDK mode toggle state via `UsageData.codexSDKModeActive`.
    /// Used by iOS to render "· SDK mode" vs "· disk mode" on the Codex
    /// analytics subtitle. When false, iOS assumes disk mode.
    public static func supportsCodexSDK(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= codexSDKMinimum
    }

    /// Whether the paired Mac is wire v9+ and therefore exposes the
    /// Chat tab endpoints. iOS gates Chat tab visibility on this.
    public static func supportsChat(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= chatMinimum
    }

    /// Whether the paired Mac is wire v9+ and therefore exposes the
    /// Frontier endpoints. iOS gates the (v0.9) Frontier UI on this.
    public static func supportsFrontier(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= frontierMinimum
    }

    /// Whether the paired Mac is wire v9+ and therefore honors the
    /// per-request `codexChatBackend` override on `POST /chat-sessions`.
    public static func supportsCodexChatBackend(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= codexChatBackendMinimum
    }

    /// Whether the paired Mac is wire v11+ and therefore exposes
    /// Antigravity 2 chat via the daemon's `POST /sessions` endpoint.
    /// v0.8.1 (wire v10) migrated only the Mac UI's spawn path; iOS's
    /// daemon-initiated start path waits for v0.8.2 (wire v11). When
    /// false, iOS surfaces "Update Clawdmeter on Mac" instead of
    /// posting to an endpoint that lands in a legacy direct-argv path.
    public static func supportsAntigravityChat(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= antigravityChatMinimum
    }

    /// Whether the paired Mac is wire v14+ and therefore emits per-turn
    /// lifecycle transitions on `WireChatSnapshot.currentTurnState`. iOS
    /// ChatV2 reads this to know whether to trust the field (vs falling
    /// back to a heartbeat heuristic).
    public static func supportsTurnLifecycle(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= turnLifecycleMinimum
    }

    /// Whether the paired Mac honors the `deepResearch` field on chat
    /// create requests. Older Macs decode it but ignore it; the V2
    /// composer surfaces a banner instead of letting Deep Research
    /// silently degrade.
    public static func supportsDeepResearch(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= deepResearchMinimum
    }

    /// Whether the paired Mac exposes the `GET /chat-sessions/search`
    /// endpoint. The V2 sidebar uses this for full-history search;
    /// when false, the sidebar reverts to grepping the local LRU cache
    /// and labels the result "Recent only".
    public static func supportsChatSearch(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= chatSearchMinimum
    }

    /// Whether the paired Mac exposes Code V2's durable workspace/runtime
    /// binding fields. UI can render legacy sessions normally when false,
    /// but should hide workspace archive / command-receipt affordances.
    public static func supportsCodeV2ControlPlane(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= codeV2Minimum
    }

    /// Whether the paired Mac exposes the v16 `/workspaces` endpoints.
    public static func supportsWorkspaces(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= workspacesMinimum
    }

    /// Whether the paired Mac exposes vendor CLI/MCP provisioning routes.
    public static func supportsVendorProvisioning(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= vendorProvisioningMinimum
    }

    public static func supportsRevive(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= reviveMinimum
    }

    /// Whether the paired Mac honors the v16 idempotency key + receipt
    /// contract across every write endpoint. When false, the iOS outbox
    /// still enqueues + retries — the server just doesn't dedup, so a
    /// dropped Wi-Fi mid-retry on an older Mac could double-send. iOS
    /// surfaces a banner when this is false and pending entries exist.
    public static func supportsMobileOutbox(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= mobileOutboxMinimum
    }

    /// Whether the paired Mac exposes Cursor as a first-class provider.
    public static func supportsCursor(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= cursorMinimum
    }

    /// Whether the paired Mac can host iOS Code Run/Preview + checkpoint
    /// restore flows through real daemon endpoints.
    public static func supportsCodeWorkbenchRemote(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= codeWorkbenchRemoteMinimum
    }

    /// Whether the paired Mac exposes unified lifecycle snapshots.
    public static func supportsLifecycle(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= lifecycleMinimum
    }

    /// Whether the paired Mac exposes `GET /provider-defaults` and
    /// `PUT /provider-defaults/:vendor`. Older Macs keep local/default
    /// catalog behavior and never block session creation.
    public static func supportsProviderDefaults(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= providerDefaultsMinimum
    }

    /// Whether the paired Mac honors the `providerInstanceId` field on
    /// session DTOs and exposes per-instance keys on the `UsageEnvelope`
    /// `usage` dict. Older Macs ignore the field and resolve every
    /// request to `ProviderInstanceId.primary(kind:)` — the back-compat
    /// default. F3-wire (Codex eng-review #10).
    public static func supportsProviderInstance(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= providerInstanceMinimum
    }

    /// Whether the paired Mac supports the chat shell/detail split on the
    /// `chat-subscribe` WS (A10). Returns true iff `serverWireVersion >= 21`.
    /// Clients on `serverWireVersion <= 20` keep receiving the full
    /// `WireChatSnapshot` per commit.
    public static func supportsShellDetail(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= shellDetailMinimum
    }

    /// Whether the paired Mac includes workspace-tab inherited context
    /// metadata on session payloads.
    public static func supportsTabContext(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= tabContextMinimum
    }

    /// Whether the paired Mac supports the Add-Repo workspace-onboarding
    /// flow (Open Project / Clone from GitHub / Quick Start). iOS gates
    /// the workspace switcher's "+ Add project" footer on this; older
    /// Macs see no footer and a banner saying to update.
    public static func supportsWorkspaceOnboarding(serverWireVersion: Int?) -> Bool {
        guard let v = serverWireVersion else { return false }
        return v >= workspaceOnboardingMinimum
    }
}
