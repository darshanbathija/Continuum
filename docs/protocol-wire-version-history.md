# AgentControl Wire Version History

Historical bump notes moved out of `AgentControlWireVersion.swift` so protocol code stays focused on current gates. Keep new bump detail here and keep only the active constant/minimum in code.

Wire version. Bump when adding a new WS op, REST endpoint, or DTO that
older Macs won't recognize so iOS can fall back gracefully.
v4 (2026-05-18) adds `compose-draft` WS op (X1 cross-Apple handoff).
v5 (2026-05-19) Phase 0a: `WireChatSnapshot.updateCounter` is now
populated from the daemon-owned `SessionChatStore.updateCounter`
(transcript counter) instead of `session.lastEventSeq` (registry/
status counter). The field name and shape are unchanged; only the
semantics shift, so v4 iOS clients keep working. Phase 0a also
introduces the `chat-subscribe` WS op (lands in Phase 2).
v6 (2026-05-19) Gemini provider: extends `AgentKind` with `.gemini`;
`ModelCatalog` gains `gemini` array; `/usage` envelope ships in
dual-shape (legacy `{claude, codex}` + new `usage: [String: UsageData]`
dict) with PER-PROVIDER fallback in v6 readers (X1 fix: prefer
`usage[id]`, fall back to legacy `<id>` for each provider
independently — prevents data-loss when dict is partial).
v7 (2026-05-20) Antigravity 2 native: new `/sessions/:id/antigravity-plan`
REST endpoint + `antigravity-plan-subscribe` WS op; new
`AntigravityPlanSnapshot` DTO. `UsageData` gains optional
`antigravityModel: String?` + `sdkModeActive: Bool?` fields
(decodeIfPresent; back-compat preserved). The `usage[id]` dict key
STAYS "gemini" through v7 per locked decision D5 — never rename
to "antigravity" because v6 iOS clients use the per-provider
fallback that keys on "gemini" literally; renaming would silently
strand iOS data.
v8 (2026-05-20) Codex SDK observation mode: `UsageData` gains
optional `codexSDKModeActive: Bool?` field (decodeIfPresent —
back-compat preserved). New `codexSDKMinimum = 8` gate +
`supportsCodexSDK(serverWireVersion:)` helper. No new endpoints
or WS ops in v8 — the SDK observation mode rides on the existing
`/usage` envelope; the field tells iOS to render "· SDK mode" on
the Codex analytics subtitle.
v9 (2026-05-21) Chat tab: new endpoints (POST /chat-sessions,
POST /chat-sessions/frontier/*, GET /chat-providers) + Frontier
WS op (`frontier-subscribe`). AgentSession schema v5 adds
optional `kind`, `frontierGroupId`, `frontierChildIndex`,
`codexChatBackend`, `codexChatThreadId`; `repoKey` becomes
optional. New `chatMinimum/frontierMinimum/codexChatBackendMinimum`
= 9 gates. iOS Chat tab gates on `serverWireVersion >= chatMinimum`.
v10 (2026-05-21) Antigravity 2 native chat via `agentapi`:
`AgentSession` gains optional `geminiBackend: GeminiBackend?`
+ `antigravityConversationId: UUID?` (schema v5→v6). `usage[id]`
dict key transitions from `"gemini"` literal to `"antigravity"`,
with dual-decoder fallback (`usage["antigravity"]` first →
`usage["gemini"]`). New `agentapiMinimum = 10` +
`antigravityChatMinimum = 11` (deferred to v0.8.2 until daemon
POST /sessions also dispatches via agentapi — Codex P1.4).
Gates surface "Update Clawdmeter on Mac" copy on older iOS
instead of letting them render a stale Gemini UI.
v11 (2026-05-21) Gemini chat live via daemon: POST /chat-sessions
now dispatches `provider: "gemini"` to agentapi (lifts the v0.8
501 stub). `AgentSession` gains optional `antigravityProjectId:
String?` (additive — decoder-tolerant, no formal schema bump).
`antigravityChatMinimum = 11` is now reachable.
v12 (2026-05-22, X3 hardening for PR #28 OpenCode): `AgentKind`
gains a `.unknown` sentinel + the decoder folds unknown raws
into it instead of `.claude`. Older v11 clients reading a v13
(OpenCode) payload still drop into the silently-mislabeled
`.claude` path — they get the audit-flagged bug. v12+ clients
reading v13 payloads render the new kind as "Other agent" via
the UI fallback rather than misclassifying.
v13 (2026-05-22, D11/D12 — OpenCode adapter): adds
`AgentKind.opencode` + `UsageRecord.Provider.opencode`. v12
clients decode the new raw as `.unknown` (the X3 fallback);
v13+ clients decode as `.opencode` natively. Schema migration
audited across `AnalyticsDailyChart` + every `byProvider:`
consumer.
v14 (2026-05-23, Chat V2): explicit per-turn lifecycle on the
snapshot wire (`WireChatSnapshot.currentTurnState: TurnState`)
emitted from each provider's natural end-marker (Claude's
`result` line, Codex SDK's `turn.completed`, Antigravity's
`chunk_done`). New Deep Research toggle on
`CreateChatSessionRequest`, `FrontierModelSlot`, and the
`AgentSession` registry record (so the bool survives respawn
/ restore / retry). New `GET /chat-sessions/search?q=` history
search endpoint walking JSONL on disk. All additive +
decodeIfPresent: older Macs/clients see decode-default values
without crashing.
v15 (2026-05-23, Code V2 control plane): additive durable workspace,
runtime binding, provider-event, mobile-command, billing-confidence,
and PR mirror DTOs. `AgentSession` gains optional workspace/runtime
fields and explicit `runtimeCwd` / `chatCwd` so chat sessions stop
overloading `worktreePath` as their cwd. `ModelCatalog` gains an
OpenCode bucket plus provider-indexed accessors.
v16 (2026-05-23, Code V2 deferred follow-ups ship): adds persisted
workspace store (`GET /workspaces`, `PATCH /workspaces/:id`), uniform
idempotency-key + receipt across every write endpoint (send,
approve, interrupt, change-model/effort/mode, autopilot, pick-winner),
MagicDNS-first pairing host preference + forward-compat
`clawdmeters://` TLS scheme. Older Macs return 404 on the workspace
endpoints; iOS falls back to per-session repo bucketing.
v17 (2026-05-24, Cursor provider): adds `AgentKind.cursor`,
`SessionRuntimeKind.cursorCLI`, a Cursor model bucket in
`ModelCatalog`, and `cursorMinimum`. Cursor sessions are Mac-launched
through `cursor-agent` / `agent`; iOS sends the same `/sessions`
request to the paired Mac and never runs the Cursor CLI locally.
v18 (2026-05-25, iOS Code workbench parity): adds remote Mac-backed
run profile endpoints plus checkpoint create / restore-preview /
restore endpoints so iOS can expose the same Code workbench lifecycle
without pretending it can run local shell commands on-device.
v19 (2026-05-25): adds `SessionLifecycleSnapshot`,
`GET /sessions/:id/lifecycle`, the `lifecycle-subscribe` WS op,
and provider default endpoints (`GET /provider-defaults`,
`PUT /provider-defaults/:vendor`). v18 `AgentSession.status`
remains the compatibility status for older clients.
v20 (2026-05-26, F3-wire): adds optional `providerInstanceId: String?`
to `NewSessionRequest`, `ChangeModelRequest`, `ChangeModeRequest`,
`ChangeEffortRequest`, and `AgentSession` so chats and sessions can
pin to a specific configured `ProviderInstanceId` (claude_personal
vs claude_work; codex_pro vs codex_oss). `UsageEnvelope.usage` now
keys by `ProviderInstanceId.wireId` (e.g. `claude/__primary__`,
`claude/work`) alongside the existing `AgentKind.rawValue` keys —
dual-shape so v19 clients reading a v20 server still see their
primary-keyed data, and v20 clients reading a v19 server fall back
to the legacy key. **Codex eng-review #10 security wire-up:**
daemon HOME isolation + Keychain access-group partitioning +
env scrubbing for per-instance child processes. The plan reference
for the wire-only counterpart (without the daemon enforcement) is
a future task; this PR ships both the wire and the enforcement
together so older v19 clients always degrade safely to the
primary instance (Codex #10 acceptance: clients on `wireVersion
< providerInstanceMinimum` only ever see/select the primary).
v21 (2026-05-27, A10): chat stream is split into a thin
`ChatShellEvent` (header: session id, sequence number, kind,
emittedAt, optional token counts — typically ~80 bytes) and a
heavy `ChatDetailEvent` (full text, tool calls, plan steps,
source entries, artifacts). v21+ clients receive shell + detail
pairs on the `chat-subscribe` WS; v20 and below receive the full
`WireChatSnapshot` on each commit (back-compat). The dispatch
branch is selected once per connection from the client's
`wireVersion` field on the subscribe envelope. Drives ≥80%
payload reduction during token-burst streaming by deferring the
heavy fields to a separate frame that consumers can render
after the shell summary lands. Non-chat events (lifecycle,
usage, etc.) keep their existing single-frame shape.
v22 (2026-05-27): workspace session tabs. `AgentSession` gains
optional `inheritedContextSourceIds` so a newly-created code tab
can audit which sibling transcripts seeded its first prompt, plus
`ownsWorktree` so same-workspace tabs can share a cwd without
inheriting destructive worktree-delete ownership.
v23 (2026-05-27): workspace onboarding endpoints. Five new routes
for the Code-tab Add-Repo flow (`POST /workspaces/open-local`,
`/from-github`, `/quick-start`, `/wake-mac`, `GET /workspaces/allow-list`).
Mac drives the local Add-Repo menu; iOS posts the same payloads via
`MobileCommandOutbox` so a paired iPhone can clone or quick-start a
repo on the Mac. Older clients 404 the routes; iOS surfaces an
"Update Clawdmeter on the Mac" banner when `serverWireVersion < 23`.
v24 (2026-05-27): vendor provisioning endpoints. Adds read-only
catalog/device checks plus explicit terminal-launched CLI install/auth
actions and repo-env preview/import routes backed by PR 201's
`RepoEnvStore` + Keychain custody.
v27 (2026-06): Code-tab harness migration. `NewSessionRequest` gains
optional `existingWorkspacePath` + `sessionId` so the Mac Code tab can
route codex/cursor/gemini spawns through the daemon's ACP harness
(reusing a Mac-provisioned worktree + pre-minted id) instead of building
tmux argv. Both fields decode-if-present, so older daemons ignore them
and older clients omit them — back-compat preserved. `harnessSpawnMinimum
= 27` gates the Mac fork.
v28 (2026-06-11): multi-account subscriptions v1. Adds
`GET /provider-instances` returning `ProviderInstanceListResponse` of
path-free `ProviderInstanceDTO`s (wireId, kind, name, isPrimary,
displayName — config roots are Mac-local and never cross the wire),
plus optional `providerInstanceId: String?` on
`CreateChatSessionRequest` (decode-if-present) so a chat can pin to a
configured account; unknown wireIds are rejected at create (422),
never silently re-billed to the primary. The `/usage` envelope gains
per-SECONDARY-instance keys (`claude/work`) next to the legacy kind
keys (primaries stay on the legacy keys), surfaced via
`UsageEnvelope.secondaryInstanceUsage()`. `providerInstanceListMinimum
= 28` gates the Mac + iOS account pickers; clients paired to a Mac on
wire < 28 hide the pickers entirely and keep primary-only behavior.
v29 (2026-06): custom OpenAI/Anthropic-compatible providers. Adds
`ModelCatalog.customProviders`, `customProviderId` on session/chat DTOs,
`GET /custom-providers`, and `ChatProvidersResponse.customProviders`.
Keys never cross the wire; enablement lives on each record. Gate:
`customProvidersMinimum = 29`. (v28 = multi-account provider
instances, merged in PR #304 — see the v28 entry above.)
