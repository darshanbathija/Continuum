# Continuum 2026-Q2 / Q3 Roadmap

**Date:** 2026-06-01
**Codebase:** v0.29.30 build 169
**Inputs:** `docs/competitive_analysis.md` (May 25) + `docs/clawdmeter-competitive-analysis-report.md` (May 30) + `docs/go-to-market-strategy-mobile-first-ide.md` + fresh external intel on Conductor v0.28–0.29 + Cursor 2.0–3.5 + the v0.29.30 codebase

---

## TL;DR — My Thesis

The May 30 report's "Conductor-Killer / Cursor-Complement / Mobile-Polish" framing is right, but I'd restructure by **defense vs offense** rather than by competitor:

- **Defensive (this quarter):** close the 4 specific gaps Conductor v0.28–0.29 opened (`conductor.json` setup scripts, Linear ingestion, diff commenting with GitHub sync, merge-blocking todos) before they become table-stakes.
- **Offensive (this quarter):** push the mobile wedge hard — relay GA, Watch 4-complication family, voice handoff — because **neither competitor has any of this and both are raising rounds to build AI platforms, not Apple Watch apps.**
- **Strategic (next quarter):** cost-aware fleet dashboard as the new north-star. Continuum is the only product that can show "this $200/day in Opus is going to the auth-service PR, the redis PR, and a dead-end spike." Cursor hides cost. Conductor ignores it.

The single sentence I'd put on the homepage:

> "Run 3 Claude + 2 Codex + 1 Gemini in parallel. Voice-spawn the 7th from your watch. Approve plans from your lock screen. See the per-PR cost in real time. Migrate from Conductor in one click. Works offline. $0/month."

That's the wedge. Everything below is the path to shipping it.

---

## What Shipped at the Competitors Since May 30 (Fresh External Intel)

| Competitor | What landed | Continuum implication |
| --- | --- | --- |
| **Conductor v0.28.0–0.29.1** (Dec 2025 – Jan 2026) | Workspaces history, `.context` dir, **diff commenting + GitHub sync** (v0.29.0), **merge-blocking todos in Notes** (v0.28.4), per-repo customizable review/PR/branch-rename prompts (v0.29.1), **Claude + Codex chats simultaneously when custom keys set** (recent) | Conductor is closing the multi-model gap. Their A/B mode and our Broadcast are now in the same neighborhood. Linear integration is on their roadmap but not shipped. |
| **Cursor 2.0** (Oct 2025) | Composer model (4× faster), Multi-Agent Interface, native browser integration, **agent-centric UI** | Cursor repositioned from "AI editor" to "AI platform with editor." Continuum's "cockpit for the swarm" framing is now directly competitive. |
| **Cursor 3.0** (Apr 2026) | Composer 2 (61.3 CursorBench, 200 tok/s), up to 8 parallel agents, **Background Agents GA**, **Cloud Agents** | Now matches our "fleet" story but theirs is local-or-cloud. Owns "private by design" if we stay local-only. |
| **Cursor 3.5** (May 20 2026) | **Cursor Automations** in Agents Window, **multi-repo automations**, scheduled runs, `/loop` skill | Their answer to our `SessionScheduler` (G15). We need to ship the UX or they own "recurring agents." |
| **Cursor CLI** (Jan 2026 → stable) | Plan/Ask modes, **cloud handoff** (prepend `&` to message), one-click MCP auth, `/loop`, headless invocation (`cursor --headless`), stable across desktop OSes | Cursor CLI is now a real headless agent. **A `cursor --headless` shim that pipes into our daemon would be huge for CI users** — zero-friction adoption path. |
| **Cursor mobile** | Native iOS + Android app for kicking off tasks, getting a PR before you're at your desk | Closes the mobile gap from their side. **But: still no Apple Watch, no Live Activities, no mid-run steering, no voice.** |
| **Cursor BugBot** (Feb 2026 GA) | $40/user/mo GitHub PR reviewer, separate from editor plans | Continuum's `PRMirror` is free and in-app. Position: "BugBot is great, but we surface PR review inside your fleet dashboard, not as a separate $40 sub." |
| **Cursor Hooks** (2026) | `onPreEdit`, `onPostEdit`, `onPreCommit`, `onApprove` — Bash/Node/Python in `.cursor/hooks/` | Continuum can ship a similar `preSend`/`postEdit` hook system on the daemon. Not P0, easy P2. |
| **SpaceX $60B Cursor acquisition rumor** | In negotiation as of Apr 2026; if closes, Composer 2 might swap to Grok variant | If true, Continuum's vendor-agnostic positioning gets even stronger. Worth watching the deal. |

**Two things I want to call out explicitly that the existing reports don't have:**

1. **Cursor's Composer 2 is in trouble in the model picker** — there's an open forum thread (cursor.com/t/158244) where users report the Composer 2 option is missing from the dropdown on macOS. Manual workaround in settings. This is a known regression as of late May. Continuum's macOS-native model picker that works is, ironically, a real differentiator right now.
2. **Conductor's "0.36+ on the way" rumors + Superset/Intent/Vibe Kanban all closing the same gap** — the parallel-orchestrator category is consolidating fast. We have maybe 2 quarters before the visual-fleet-board story becomes table-stakes and we have to differentiate on the *only* things that nobody else can copy: Apple Watch + cost ledger.

---

## Continuum's Updated Wedge Map

**Where we WIN vs BOTH (defensible, hard to copy):**
- Apple Watch complications + Live Activities + APNS push under 2s
- Voice input (iPhone + Watch crown) for "start a session"
- Real-time $ burn on lock screen + per-PR attribution
- ccusage-parity cost analytics with repo + provider granularity
- Vendor-agnostic (Claude, Codex, Gemini/Antigravity, OpenCode, OpenRouter, Cursor-as-runtime)
- Encrypted relay pairing (E3/E4/E7) — works without Tailscale, no public IP
- Local-first privacy (no Anthropic auth needed for analytics)

**Where Conductor is catching up (need to defend):**
- A/B model comparison → we have Broadcast + pick-winner (better — multi-model, not just 2)
- Setup scripts (`conductor.json`) → **we don't have these; ship now**
- Linear integration → on their roadmap; ship ours first
- GitHub diff commenting with sync → ship in PR pane
- Multi-model simultaneous chats → we have this in v3 broadcast
- Multi-repo → on their roadmap; we have WorkspaceStore (foundation done)

**Where Cursor is catching up (need to defend):**
- Mobile (iOS app for kick-off) → we have full iOS workbench (deeper — they have kick-off, we have steering)
- 8 parallel agents → we support parallel sessions, surface them as Kanban
- Background Agents (cloud) → we are local-only, **own "private by design"**
- Automations (scheduled runs) → we have SessionScheduler (G15), need UX
- Cursor CLI (headless) → our daemon is headless already, just need a CLI shim
- Cursor Hooks → trivial to add to daemon

**Where Continuum LOSES and should not chase:**
- Custom text editor (Cursor owns this; we won't beat them)
- Cloud-hosted agents (Cursor's background agents; we own local-first)
- $200/mo max tier power (Cursor; we are $0)

---

## The Roadmap

### Tier 1 — Ship this quarter (June – August 2026)

Goal: **defend the moat + close the 4 Conductor v0.28–0.29 gaps that aren't shipped yet.**

1. **Conductor `conductor.json` setup script runner** — Closes TODOS's #1 deferred item. Run `setup` + `run` scripts inside each workspace on creation. Timeout, streaming output, audit log, no blocking modals. **Effort: 1–2 days.** *Why P0: every Conductor user evaluating us hits this gap on day 1. The cheapest possible "Conductor import" enabler.*

2. **Encrypted relay GA + APNS push default-on** — E3/E4/E6/E7 already in `[Unreleased]` per CHANGELOG. Flip the defaults, add a "Discoverable on iPhone without Tailscale" CTA in the pairing sheet. **Effort: 1–2 days.** *Why P0: 90% built per CHANGELOG; this is the #1 blocker in the GTM doc. Just ship it.*

3. **Apple Watch full 4-complication family** — `.accessoryCorner`, `.accessoryRectangular`, `.accessoryInline` (already have `.accessoryCircular` per TODOS). Live token burn + plan status + session city on every watch face. **Effort: 2–3 days.** *Why P0: no competitor will ever ship this. The single best demo in the GTM thesis.*

4. **Linear → workspace ingestion** — Mirror Conductor's roadmap. "Create workspace from Linear issue" reads the issue title + description as the initial prompt, tags the workspace, links the resulting PR back. **Effort: 3–4 days.** *Why P0: closes the "where do tasks come from?" question; Conductor has it on roadmap but not shipped yet.*

5. **GitHub PR diff commenting with sync** — Conductor v0.29.0. Comment on a hunk in Continuum's PR pane → posts as a PR review comment. Reply from GitHub → surfaces in our pane. **Effort: 1 week (gh CLI wrapper + PR pane UI).** *Why P0: review is where the team actually lives. Without it, the PR pane is a read-only viewer.*

6. **Cost-aware fleet dashboard (the new Usage tab)** — Promote the May 30 report's "Real-time per-turn $ ticker + fine attribution" item out of the Usage analytics tab. Live fleet-view: per-active-session $ burn, projected cost-to-completion, repo-level attribution, "this PR will cost $X." **Effort: 1 week.** *Why P0: this is the only moat Cursor can't easily copy and Conductor doesn't have. Make it the headline.*

7. **Voice-first new session creation (iPhone + Watch)** — "Hey Siri, start a Claude session in Continuum to fix the redis bug." Foundation Models on-device intent parse → pre-fill NewSessionSheet. **Effort: 1 day if we lean on existing `SpeechDictation` (G11); 1 week if we ship the Foundation Models intent parser.** *Why P0: Watch-crown session creation is the demo that goes viral on Twitter.*

8. **Pause/Resume the swarm** — One click suspends all running agents (kills tmux panes cleanly with checkpointing). One click resumes from the JSONL cursor. **Effort: 2–3 days.** *Why P0: "suspend overnight to save $50 in tokens" is a 5-second viral demo, and the only local product to ship it.*

### Tier 2 — Ship next quarter (September – November 2026)

Goal: **breadth on the agent-orchestration surface, plus the App Store unlock.**

9. **App Store + TestFlight path** — Paid Apple Developer Program, App Store Connect API, TestFlight pipeline. **Effort: 1 day for setup, ongoing review process.** *Why P1: until this ships, iOS is sideload-only. Biggest growth unlock.*

10. **Multi-repo workspaces** — Conductor's roadmap item. A workspace that spans `~/code/api/` + `~/code/web/` + `~/code/shared/`. Cross-repo changes in one agent. **Effort: 2–3 weeks.** *Why P1: monorepo is the single biggest reason power users pick Conductor over us.*

11. **Multi-Mac federation** — One iPhone, multiple paired Macs. Per-Mac pairing tokens. Sessions grouped by host. **Effort: 1 week.** *Why P1: in TODOS as long-deferred; the user has 2+ Macs; unlocks "run agents on the laptop, approve from the desktop" workflows.*

12. **Lightweight file-level search before local RAG** — Ship ripgrep + AST-aware grep first, expose as daemon endpoint + MentionPicker. Add embeddings *only* if measurements show it actually helps. **Effort: 1 week for file-level; 2–3 weeks for embeddings.** *Why P1: closes the "I can't ask my repo questions from iPhone" gap without the 200MB+ binary cost of an embedding model.*

13. **Agent worktree collision detection** — Pre-merge analysis: "agent A edited `routing.ts` while agent B edited `auth.ts` — conflict likely on shared types. Run a review pass before merging." Both Conductor and Cursor punt on this. Continuum's `RepoIdentity` + `WorkspaceStore` is the foundation. **Effort: 1–2 weeks.** *Why P1: the obvious "swarm at scale" problem nobody has solved. Real differentiator.*

14. **Per-PR cost attribution** — Extend `UsageHistoryLoader` to track cost-by-PR (not just cost-by-repo). Show "$4.23 of Opus for the auth-service PR" on the PR card. **Effort: 1 week.** *Why P1: cost is a differentiator; per-PR is the granularity that turns "interesting" into "decision-making."*

15. **Sparkle auto-update** — Already in TODOS. Blocked on Developer ID + notarization. Pays for itself the day it ships. **Effort: 2–3 weeks (1 PoC PR + 1 implementation PR).** *Why P1: every release today requires manual DMG drag. Friction for the long tail.*

16. **Cursor CLI shim** — `cursor --headless "fix tests"` routes through our daemon, returns a Continuum session ID, the user can monitor from the app. **Effort: 2–3 days.** *Why P1: zero-friction adoption for the existing Cursor CLI user base; converts them into Continuum users without leaving their terminal.*

### Tier 3 — Strategic bets (6–12 month horizon)

17. **"Routines" — prompt-template library** — Cursor has Routines. Pre-built prompt chains for common workflows ("security audit," "migrate to Result types," "add tests for this PR"). The Skills system is the foundation; surface it as a user-curated library. **Effort: 2–3 weeks.**

18. **"Automations" — scheduled agent runs** — Cursor 3.5 added this. Continuum has `SessionScheduler` (G15) but no UX. Cron-style "every weekday at 9am, run the dependency-update agent on repo X." **Effort: 1–2 weeks.**

19. **Conductor import** — One-click migration from `~/conductor/workspaces/`. Reads their workspace state, preserves branches + setup scripts, re-homes into Continuum sessions. Conductor is the on-ramp; Continuum is the destination. **Effort: 1–2 weeks.**

20. **Public benchmark suite** — "Continuum orchestrates 8 agents in parallel at $X/hour with Y% success rate." Reproducible methodology, published numbers. The marketing wedge for power users. **Effort: 1 week.**

21. **Agent health pulse dashboard** — "Last 7 days: 23 sessions, 18 finished cleanly, 3 timed out, 2 OOM-killed." Both competitors lack. Continuum's chat store + analytics is the foundation. **Effort: 1–2 weeks.**

22. **Mac launch agent (daemon survives app quit)** — In TODOS as long-deferred. The Mac daemon stops when the Continuum Mac app quits. A `LaunchAgent` would keep it running headless. **Effort: 3–4 days.** *Why Tier 3: needed for any "I'm on my phone and the Mac lid is closed" workflow to actually work. Don't ship before APNS relay GA — the relay is more important.*

---

## What I'd CUT (or push to Tier 4 / never)

- **"Local RAG with vector embeddings" before file-level:** ship file-level search first (just ripgrep + AST-aware grep), add embeddings only after measuring whether it actually helps. The cost of a good local embedding model is 200MB+ of binary and a real perf hit.
- **Full WCAG AA on every surface:** ship AA on the 5 critical user flows, audit the rest over time. Don't block the roadmap on this.
- **Custom editor surface:** we will never beat Cursor at being a text editor. Don't try. The "send to Continuum" shim is enough.
- **Native Cloud Agents (Cursor-style cloud background):** out of scope. Local-first is the brand. If users want cloud, they can use Cursor for that and Continuum for everything else.
- **Full E2E test suite (T16) before Tier 1 ships:** ship a critical-path smoke test only; let Tier 2 expand coverage. Test debt is fine for a one-person team shipping daily.
- **GitHub Issues importer** (vs Linear): GitHub Issues matters but Linear is the wedge for the existing Conductor user base. Do GitHub Issues in Tier 3 if there's demand.

---

## Cross-Cutting Bets

- **Apple Developer Program enrollment ($99/yr)** — unblocks TestFlight, Sparkle, multi-Mac iOS install, and notarization. Ship before Tier 1 ends. The single highest-ROI spend in the whole roadmap.
- **Per-session cost budget + mid-session alerts** — the GTM doc's preflight cost banner is shipped (v2.0.1), but we don't yet warn mid-session when a session is 2× over its projected cost. Add a "this Opus session is at $5 and counting — interrupt?" prompt. **Effort: 2 days.**
- **`conductor.json` format as a community RFC** — when we ship the runner, propose the format as a community RFC. First-mover advantage in agent-orchestration schema is rare.
- **Public `ROADMAP.md` on the GitHub repo** — `TODOS.md` is internal. A curated, dated "what's shipping next" doc builds trust with the closed beta and reduces "is this alive?" uncertainty.

---

## What I'd Start on Monday

Three things, in order, if I were the dev:

1. **`conductor.json` runner** (Tier 1 #1) — 1–2 days, closes the #1 documented gap. Existing Conductor users will try us, see this is missing, and leave. Easy.
2. **Relay GA + APNS default-on** (Tier 1 #2) — already 90% built per CHANGELOG. Just flip the defaults, add the discoverability CTA, ship.
3. **Cost-aware fleet dashboard** (Tier 1 #6) — the new Usage tab. This is the moat. Make it the headline.

If those three land in the next 30 days, the homepage tagline above stops being aspirational. It becomes a product fact.

---

## Open Questions (worth a 30-min conversation)

1. **Apple Developer Program enrollment timing** — is there a reason we're still on Personal Team? The blockers in TODOS are real but the cost is now blocking ~$200K/yr worth of work (Sparkle, TestFlight, multi-Mac iOS).
2. **Cloud Agents strategy** — if Cursor's Cloud Agents (Max tier $200/mo) start eating into the "I want agents that survive my laptop closing" market, do we (a) ignore it and double down on local, (b) build a "rent a Mac" relay, or (c) ship a thin client that runs in the user's iCloud / hosted Mac provider? The answer shapes the local-first roadmap.
3. **Naming the cost-aware fleet dashboard** — "Cockpit"? "Bridge"? "Mission Control" (taken by Antigravity)? The name matters for marketing.

---

*This document intentionally references and builds on the existing `docs/competitive_analysis.md` and `docs/clawdmeter-competitive-analysis-report.md` rather than duplicating them. Those remain the deep feature-by-feature and architecture reviews. This is the "what to ship next" layer on top.*
