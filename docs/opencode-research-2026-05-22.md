# OpenCode vs. build-from-scratch — deep research

Recorded 2026-05-22. Triggering decisions: **D11** (hybrid — keep Swift
harness, add OpenCode as a provider) and **D12** (standalone PR #27
post-v1.0). See `docs/button-wiring-audit.md` for the decisions table.

---

## TL;DR

Do not fork OpenCode. Keep building Clawdmeter's Swift agent harness,
and instead use OpenCode's HTTP server as **one more provider**
alongside Claude Code / Codex / Antigravity — a coexistence, not a
replacement. OpenCode is a 164k-star TypeScript/Bun system that
*replaces* the agent CLIs by calling provider APIs directly, but
Clawdmeter's whole value proposition is being a meter and control
surface for the user's existing CLIs and their OAuth tokens; forking
would force a rewrite of the harness, throw away iOS portability (Bun
won't run on iOS), and turn the app into "just another OpenCode skin"
with worse cross-Apple integration.

---

## What OpenCode actually is

Leading candidate is unambiguously **[sst/opencode](https://github.com/sst/opencode)** — the
SST-team-built, [opencode.ai](https://opencode.ai/)-hosted open-source AI coding agent. Launched June 2025
and currently the fastest-growing OSS dev tool of the cycle.

- **Stars:** 164k. **Forks:** 19.3k. **Releases:** 809 (a release every 1-2 days,
  multiple per day in the past week). **Current:** v1.15.7 (2026-05-21).
- **License:** MIT. Fork-and-relicense safe; no GPL contagion.
- **Architecture** ([deepwiki/sst/opencode](https://deepwiki.com/sst/opencode)):
  Bun workspace monorepo, 20+ packages, Turbo-orchestrated, TypeScript 65.7% / MDX 30.9%
  (no Go anymore — Bubble Tea was retired at v1.0 in favor of an in-house TypeScript
  TUI on Zig-backed [OpenTUI](https://github.com/sst/opentui)).
- **Client/server split.** `opencode serve` is the daemon — an HTTP server using **Hono**,
  backed by **SQLite + Drizzle ORM**, with an event-sourced session model. Every other
  surface (TUI, Electron desktop, web, VS Code extension, third-party iOS clients) is a
  client over HTTP + SSE.
- **50+ REST endpoints** organized into Global / Project/Path/VCS / Sessions / Messages /
  Files / Config/Providers / Commands/Tools / LSP/MCP, plus a `/tui` namespace.
  SSE at `/event` for streaming.
- **Auth:** HTTP Basic via `OPENCODE_SERVER_PASSWORD`. Default bind `127.0.0.1:4096`.
  Optional mDNS for LAN discovery.
- **TypeScript SDK ships as `@opencode-ai/sdk`. No Swift SDK.**

### How it talks to LLMs

**Vercel AI SDK** with lazy-loaded `@ai-sdk/anthropic`, `@ai-sdk/openai`, `@ai-sdk/google`,
plus `@modelcontextprotocol/sdk` for MCP servers. **It does not wrap `claude` / `codex` /
Antigravity CLIs — it replaces them**, calling provider APIs directly with model
metadata pulled from models.dev (75+ providers).

### Built-in features

- **Two primary agents:** `build` (all tools) and `plan` (file edits + bash gated to `ask`).
  Three sub-agents: general, explore, scout.
- **Custom agent definitions** via markdown files in `~/.config/opencode/agents/`.
- **Worktrees first-class** at the project level, `opencode/<slug>` branch convention,
  `Project.Info.sandboxes[]` tracks active worktrees.
- **MCP server hosting** (stdio + remote HTTP/SSE, with OAuth).
- **LSP integration** for navigation.
- `opencode run --format json` for one-shot scripted runs.

### Ecosystem on top

- [`grapeot/opencode_ios_client`](https://github.com/grapeot/opencode_ios_client) — native Swift, MIT, 168 stars.
- [`Shahfarzane/opencode-mobile`](https://github.com/Shahfarzane/opencode-mobile) — Expo/React Native.
- [`itswendell/palot`](https://github.com/itswendell/palot) — Electron multi-session GUI.
- [Mobile-version feature request](https://github.com/sst/opencode/issues/10288) — not on SST's roadmap.

---

## Capability matrix

| Capability | OpenCode (v1.15.7) | Clawdmeter today |
|---|---|---|
| **License** | MIT | proprietary |
| **Wire protocol** | HTTP/REST + SSE (Hono, OpenAPI 3.1) | HTTP + WS on 21731/21732 (Network.framework), wire-v5 |
| **Runtime** | Bun (preferred) / Node | Swift native (Mac daemon + iOS client) |
| **Multi-provider Claude/Codex/Gemini** | ✓ via Vercel AI SDK (direct API) | ✓ via wrapping each official CLI |
| **Uses user's existing CLI OAuth** | ✗ requires its own provider auth | ✓ reads `claude` Keychain token, Codex token, AGY token |
| **Plan mode + approve-and-run** | ✓ "plan" agent with restricted tools | ✓ `--permission-mode plan` / `--sandbox read-only`, Approve & Run gesture |
| **Worktree spawning** | ✓ project-level, `opencode/<slug>` branches | ✓ `WorktreeManager.swift`, per-session worktrees |
| **Live terminal stream** | ✓ via `@lydell/node-pty` (server-owned) | ✓ tmux supervisor + `MacTerminalView`, `Cmd+T` overlay |
| **JSONL transcript** | event-sourced SQLite (replayable) | reads CLI's own JSONL — ccusage-compatible |
| **Cancellation / interrupt** | implicit via session state | ✓ `interruptSession`, full plumbing through daemon |
| **Streaming tokens** | SSE | WebSocket with 100ms coalesce |
| **MCP host** | ✓ stdio + HTTP/SSE + OAuth | ✗ (deferred) |
| **Multi-session / multi-repo parallel** | ✓ via per-worktree sandboxes | ✓ `AgentSessionRegistry` + per-repo trust list |
| **A/B "frontier" pairing** | ✗ | ✓ `createFrontier` / `frontierPickWinner` |
| **Live cost ticker / token meter** | ✗ no built-in $/token analytics | ✓ this is the product — `LiveCostCalculator`, ccusage-style |
| **Native macOS UI** | Electron app (default channel) | ✓ AppKit/SwiftUI menu bar + window, Tahoe Liquid Glass |
| **Native iOS UI** | ✗ no official; 3rd-party Swift client | ✓ first-party `ClawdmeteriOS`, daemon-paired |
| **Apple Watch / widgets** | ✗ | ✓ complications + widgets across watchOS, iOS, macOS |
| **Push-based mobile updates** | ✗ poll-only HTTP | ✓ wire-v5 `chat-subscribe` WS push, 100ms coalesce |
| **Mac menu-bar gauge** | ✗ | ✓ the original product |
| **OAuth handover from existing CLIs** | ✗ | ✓ reads Keychain + Codex/AGY creds — no re-auth |
| **GitHub stars / momentum** | 164k, ~30 commits/day | private repo, single-team |

---

## Integration model if we forked (rejected)

**Architecture sketch:** Clawdmeter.app ships the Tahoe SwiftUI Code tab as today, but
instead of `MacCodeView` reading from `runtime.agentSessionRegistry`, it talks over HTTP+SSE
to an embedded `opencode serve` sidecar bundled inside the `.app`. The sidecar is a
Bun-compiled single-file binary (~150-200MB). All harness pieces — `TmuxSupervisor`,
`AgentSpawner`, `WorktreeManager`, `CodexSDKManager`, `AntigravitySidecarManager` — are
**retired in favor of opencode's equivalents** because opencode replaces the user's CLIs
entirely.

**iOS path falls apart:** Bun does not run on iOS. App Store policy prohibits JIT'd
runtimes, and even Node/Bun-as-AOT-binary requires private entitlements no consumer app
gets. iOS users would either lose the local-daemon model entirely (Mac-only sessions,
phone is pure remote control) or you'd keep the Swift daemon-client model anyway, meaning
opencode is *only* an additional Mac-side process and you've gained nothing on iOS.

**Estimated effort to ship Tahoe-on-OpenCode v1.0:** ~3-4 months of demolition +
reconstruction before any new UX ships, plus the 5-tab review pane still has to be
built on top after that.

---

## Integration model: hybrid (chosen)

**v1.0 ships without OpenCode** — Phase D (Code IDE) and Phase E (Chat pipeline) land
on the Swift harness as planned. v1.0 has Claude / Codex / Antigravity as agent kinds.

**v1.1 adds OpenCode as a fourth provider** in PR #27 (`feat/opencode-provider-adapter`).
Architecture:

```
                    Clawdmeter.app
        ┌─────────────────────────────────────────┐
        │  MacCodeView / IOSChatView / etc.       │
        │  ▲                                       │
        │  │  AgentSession event stream           │
        │  ▼                                       │
        │  AgentSessionRegistry                   │
        │  ▲      ▲      ▲      ▲                 │
        │  │      │      │      │                 │
        │  ┌──┐ ┌──┐ ┌──┐ ┌──────┐                │
        │  │CL│ │CX│ │AG│ │OPCODE│ ← new AgentKind│
        │  └──┘ └──┘ └──┘ └──┬───┘                │
        │   tmux supervisor  │                     │
        │                    ▼                     │
        │     OpencodeProcessManager               │
        │            │                             │
        └────────────┼─────────────────────────────┘
                     │ HTTP + SSE on 127.0.0.1:4096
                     ▼
              opencode serve (user-installed)
                     │
                     ▼  Vercel AI SDK
              user's Anthropic / OpenAI / Google API key
```

**Key components:**
- `OpencodeProcessManager` — peer of `CodexSDKManager`,
  `AntigravitySidecarManager`. Spawns `opencode serve` on a free port,
  manages process lifecycle, surfaces auth state.
- `AgentKind.opencode` — slots into every place that branches on agent
  kind (`AgentSession.agent`, `AgentSpawner.argv`, `iOSModelPicker`,
  NewSessionSheet provider segment, Mac chat mode toggle, Live tab
  provider segmented).
- `OpencodeSSEAdapter` — consumes OpenCode's `/event` stream, emits the
  same envelope shape our registry expects.
- `OpencodeUsageMapper` — extracts cost from OpenCode's own usage
  events (OpenCode bills against the user's API key directly, so no
  Anthropic rate-limit headers reach Clawdmeter).
- **Auth UX:** Settings → Providers shows status; first-add empty state
  reads "Run `brew install opencode` then `opencode auth login`."

---

## Risks accepted by the hybrid path

- **Maintenance surface grows.** Every OpenCode wire change is a new
  adapter version. Mitigation: pin to a tested OpenCode minor; only
  bump on demand.
- **MCP support gap remains** until we either add MCP to our Swift
  harness or route MCP through OpenCode-as-provider.
- **LSP integration gap remains** until similar.

---

## Sources

- [github.com/sst/opencode](https://github.com/sst/opencode) — repo metadata: 164k stars, 19.3k forks, MIT, TypeScript 65.7%, 809 releases, current v1.15.7 (2026-05-21).
- [github.com/sst/opencode/blob/dev/LICENSE](https://github.com/sst/opencode/blob/dev/LICENSE) — MIT license text.
- [github.com/sst/opencode/releases](https://github.com/sst/opencode/releases) — v1.15.0–v1.15.7 in the last 7 days (release cadence).
- [github.com/sst/opencode/blob/dev/packages/opencode/package.json](https://github.com/sst/opencode/blob/dev/packages/opencode/package.json) — Bun/Node dual runtime, deps: `@ai-sdk/*`, `@modelcontextprotocol/sdk`, Effect, Drizzle, `@lydell/node-pty`, Solid.js.
- [opencode.ai/docs](https://opencode.ai/docs/) — landing docs (CLI/TUI/desktop/IDE surfaces).
- [opencode.ai/docs/server/](https://opencode.ai/docs/server/) — `opencode serve`, port 4096, HTTP REST + SSE, OpenAPI 3.1, 50+ endpoints, `/tui` namespace, Basic auth.
- [opencode.ai/docs/sdk/](https://opencode.ai/docs/sdk/) — TypeScript SDK only; no Swift SDK.
- [opencode.ai/docs/agents/](https://opencode.ai/docs/agents/) — build/plan primary agents; explore/scout/general sub-agents; markdown agent defs.
- [opencode.ai/docs/cli/](https://opencode.ai/docs/cli/) — `serve`, `run --format json`, `session`, `agent` subcommands.
- [deepwiki.com/sst/opencode](https://deepwiki.com/sst/opencode) — monorepo architecture, package map.
- [deepwiki.com/sst/opencode/2-session-and-state](https://deepwiki.com/sst/opencode/2-session-and-state) — SQLite + Drizzle, event-sourced sessions via `SyncEvent`.
- [deepwiki.com/sst/opencode/2.7-project-and-worktree-management](https://deepwiki.com/sst/opencode/2.7-project-and-worktree-management) — project-level worktrees, `opencode/<slug>` branches.
- [deepwiki.com/sst/opencode/4-tool-system](https://deepwiki.com/sst/opencode/4-tool-system) — Vercel AI SDK direct provider calls; not a CLI bridge.
- [ggprompts.com/architecture/opencode](https://ggprompts.com/architecture/opencode/) — Hono framework + REST/SSE + multiple-client model.
- [dev.to/brendonovich/moving-opencode-desktop-to-electron-4hip](https://dev.to/brendonovich/moving-opencode-desktop-to-electron-4hip) — Electron is now the default desktop channel.
- [github.com/grapeot/opencode_ios_client](https://github.com/grapeot/opencode_ios_client) — MIT native Swift iOS client, 168 stars; proves Swift-over-HTTP integration is viable but only as a remote client to a Mac/Linux server.
- [github.com/Shahfarzane/opencode-mobile](https://github.com/Shahfarzane/opencode-mobile) — Expo/React Native client (proves no first-party mobile from SST).
- [github.com/itswendell/palot](https://github.com/itswendell/palot) — Electron multi-session GUI on top of opencode.
- [github.com/sst/opencode/issues/10288](https://github.com/sst/opencode/issues/10288) — open feature request for an official mobile/web UI; not on SST's roadmap.
- [techfundingnews.com — OpenCode background story](https://techfundingnews.com/opencode-the-background-story-on-the-most-popular-open-source-coding-agent-in-the-world/) — growth trajectory, SST backing, momentum signals.
