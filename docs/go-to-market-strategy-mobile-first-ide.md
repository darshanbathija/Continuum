# Continuum Go-To-Market Strategy

Generated: 2026-05-25
Scope: mobile-first IDE / native control plane for local coding agents

This document is meant to be executed. It synthesizes the current Continuum codebase, parallel read-only code reviews, current App Store / Google Play / SEO platform guidance, and established GTM, positioning, branding, social, SEO, ASO, product-led-growth, and demand-generation frameworks.

It does not assume Continuum is more ready than the code proves. The strongest strategy is to be unusually honest: lead with the sharp native mobile control-plane wedge, ship Mac-first, prove iPhone/Watch reliability, then scale store and community distribution.

## Executive Decision

Continuum should launch as:

> The native control plane for coding agents: run Claude, Codex, Gemini/Antigravity, OpenCode, and Cursor from your Mac, then monitor, compare, approve, and steer sessions from iPhone and Watch.

The first public GTM motion should be **Mac-first closed beta with iPhone companion**, not a broad App Store launch on day one.

Reasons:

- The Mac app is the source of truth and owns the daemon, provider runtimes, local auth, session launch, usage parsing, pairing, and diagnostics.
- The iPhone app is real and compelling, but depends on Mac pairing, Tailscale/MagicDNS, wire compatibility, and live device validation.
- The Watch story is strong for plan approval, interrupt, and glanceable status, but should not be marketed as full coding from the wrist.
- TestFlight/App Store is scaffolded but not launch-ready: Fastlane exists, but paid Developer Program, App Store Connect API, signing, review assets, privacy docs, and current physical-device validation still need to be completed.
- Linux should stay roadmap/private QA until the daemon, packaging scripts, and install artifacts are no longer skeleton/stub status.

The GTM thesis:

> Coding agents are becoming a swarm of separate CLIs, desktop apps, subscriptions, model choices, cost ledgers, and long-running sessions. Continuum wins by becoming the local, native, mobile-aware cockpit for that swarm.

## Product Truth From Code

### What Is Real Today

Code-backed product claims:

- Native Mac Tahoe shell with Chat, Usage, Code, and Settings tabs.
  - Evidence: `apple/ClawdmeterMac/Tahoe/MacRootView.swift`
- Mac Code workbench with session sidebar, center thread, review pane, plan approval, terminal, PR/diff/artifact/source panes, session restore, and workspace state.
  - Evidence: `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift`
  - Release evidence: `CHANGELOG.md` v0.29.0 build 139
- iPhone companion with Chat, Analytics, Code, pairing, new-session creation, model/effort controls, preflight cost estimate, session detail, plan/diff/PR/terminal/artifacts, and retrying command outbox.
  - Evidence: `apple/ClawdmeteriOS/Tahoe/IOSRootView.swift`, `apple/ClawdmeteriOS/NewSessionSheet.swift`, `apple/ClawdmeteriOS/Tahoe/IOSSessionDetailView.swift`, `apple/ClawdmeteriOS/AgentControl/MobileCommandOutbox.swift`
- Watch approval/glance surface for sessions needing attention.
  - Evidence: `apple/ClawdmeterWatch/SessionsListView.swift`, `apple/ClawdmeterWatch/PlanApprovalView.swift`, `apple/ClawdmeteriOS/WatchPlanBridgeIOS.swift`
- Provider/runtime abstraction for Claude, Codex, Gemini, OpenCode, and Cursor, with runtime kind separated from provider kind.
  - Evidence: `apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/Protocol.swift`
- Model optimization via model catalog, effort levels, model recommendations, context windows, preflight estimates, cap projection, and billing confidence.
  - Evidence: `Protocol.swift`, `AgentControlServer.swift`, `LiveCostCalculator.swift`, `UsageStatusChip.swift`
- Real usage analytics from local logs and provider-specific sources.
  - Evidence: `UsageHistoryLoader.swift`, `Pricing.swift`, `OpencodeUsageParser.swift`, `CursorSource.swift`
- Chat V2 with solo and broadcast/frontier comparison for the supported chat providers.
  - Evidence: `MacChatV2View.swift`, `IOSChatV2View.swift`, `ChatV2Store.swift`

### Claims To Avoid Or Qualify

Do not claim:

- "Works equally across every provider."
  - Better: "Claude, Codex, Gemini/Antigravity, OpenCode, and Cursor are first-class runtime concepts, with different capabilities depending on each upstream tool."
- "Six-provider broadcast chat."
  - Better: "Broadcast comparison for Claude, Codex, and Gemini today; Cursor and OpenCode have runtime-specific paths."
- "Cursor parity."
  - Better: "Cursor code sessions and usage visibility are integrated; Cursor chat and plan-mode semantics are intentionally gated."
- "Universal perfect cost accounting."
  - Better: "Provider-reported, locally priced, estimated, or unavailable cost confidence is shown honestly."
- "Linux is ready."
  - Better: "Linux is in progress / private QA until packaging and daemon surfaces graduate from skeleton/stub status."
- "Open source" unless LICENSE, SECURITY, CONTRIBUTING, issue templates, and public-support posture are decided.
- "App Store ready" until TestFlight/App Review readiness gates pass.

## Category And Positioning

### Category

Primary category:

> Native control plane for coding agents

Secondary category:

> Mobile-first IDE for local AI coding sessions

Why this category works:

- "IDE" alone invites comparison with Cursor, VS Code, Zed, Xcode, and web IDEs.
- "Mobile-first IDE" is differentiated, but risky unless onboarding and device reliability are excellent.
- "Control plane" fits the real architecture: Mac daemon, provider runtimes, paired iPhone/Watch, session orchestration, usage analytics, and approvals.

Use "mobile-first IDE" in narrative and App Store copy, but keep the technical headline closer to "control plane" until activation is proven.

### One-Liner

Continuum is a native Mac, iPhone, and Watch control plane for coding agents: launch sessions, compare models, track costs, approve plans, and steer long-running work from your phone.

### Short Positioning Statement

For developers who already use Claude Code, Codex, Gemini/Antigravity, OpenCode, or Cursor, Continuum is a native agent workbench that keeps sessions, cost, model choice, and mobile approvals in one local-first app. Unlike terminal-only tools or single-provider IDEs, Continuum gives you a paired iPhone and Watch cockpit for the agent stack you already use.

### Tagline Options

Use in this order:

1. "Your coding agents, in your pocket."
2. "A native cockpit for AI coding sessions."
3. "Run agents on your Mac. Steer them from your phone."
4. "The mobile control plane for coding agents."
5. "Know what your agents are doing, spending, and waiting on."

Avoid:

- "Cursor for mobile"
- "Claude Code on iPhone"
- "The best IDE"
- "Autonomous software engineer"
- "Replaces your coding tools"

## ICP

### Primary ICP

Mac-based coding-agent power users:

- Already use Claude Code, Codex, Cursor, OpenCode, Gemini, or Antigravity.
- Run long tasks in multiple repos.
- Care about model selection, effort levels, cost, quota, and plan approvals.
- Walk away from the Mac while agents run.
- Are comfortable installing a DMG from GitHub during beta.

Jobs to be done:

- "Tell me when an agent needs approval."
- "Let me approve/reject/check progress from my phone."
- "Show me what the agent is doing without SSH-ing or reopening Terminal."
- "Help me choose a cheaper/faster/smarter model before I burn the wrong quota."
- "Let me compare Claude/Codex/Gemini answers without manually copying prompts."

### Secondary ICP

Indie builders and agent-heavy founders:

- Use agents as a night/weekend development multiplier.
- Want a simple status/control app more than a full enterprise platform.
- Will share polished demos if the product feels magical.

### Tertiary ICP

Agent tool researchers and power users:

- Interested in multi-agent workflows, provider comparison, cost telemetry, and model optimization.
- Good for feedback, not necessarily the first revenue base.

### Exclusions For V1

Do not spend launch effort on:

- Non-Mac primary users.
- Enterprise security buyers.
- Android-only users.
- Beginners who have never used CLI coding agents.
- Users expecting a cloud-hosted IDE with no Mac daemon.

## Wedge

The narrow wedge:

> Start a coding session on Mac, walk away, approve the plan from iPhone or Watch, and keep the run moving.

Why it works:

- It is visceral in demos.
- It is backed by code.
- It is not easily copied by terminal-first tools.
- It makes "mobile-first IDE" concrete.
- It turns paired-device friction into a reason to exist.

The second wedge:

> Compare Claude, Codex, and Gemini in one broadcast chat, then continue with the winner.

The third wedge:

> Pick the cheapest capable model before you start with preflight cost/cap estimates.

## Branding

### Brand Role

Continuum should feel like:

- A cockpit, not a dashboard.
- A trusted local instrument, not a SaaS surveillance panel.
- A workbench, not a toy chat app.
- Native and tactile, not web-wrapper generic.

### Tone

Use:

- Direct, developer-literate copy.
- Specific provider/runtime language.
- Honest capability boundaries.
- Concrete workflow verbs: launch, resume, approve, compare, interrupt, inspect, restore.

Avoid:

- AI hype words without workflow proof.
- "Magic" as the central claim.
- "Autonomous" unless tied to concrete approval/checkpoint behavior.
- Claims that sound like remote code execution is happening from the phone without explaining the paired Mac.

### Visual System For GTM

Core visual motifs:

- Mac workbench as the base layer.
- iPhone overlay showing session control.
- Watch approval as the "aha" detail.
- Provider glyph stack.
- Cost/quota signal as small but persistent instrumentation.

Screenshot hierarchy:

1. iPhone starts or controls a session.
2. Watch approval.
3. Mac Code workbench with Plan/Diff/Terminal.
4. Broadcast comparison.
5. Usage/cost analytics.
6. Pairing and trust.

## Messaging Architecture

### H1 Options

Default website H1:

> Your coding agents, in your pocket.

Alternative technical H1:

> A native control plane for coding agents.

Alternative App Store-style H1:

> Mobile IDE for local AI agents.

### Supporting Copy

Run Claude, Codex, Gemini/Antigravity, OpenCode, and Cursor sessions from your Mac. Pair your iPhone and Watch to follow progress, approve plans, compare models, inspect diffs, track cost, and keep long-running coding work moving.

### Proof Bullets

- Start and resume local coding-agent sessions.
- Approve plans from iPhone or Watch.
- Compare Claude, Codex, and Gemini side by side.
- Track usage, spend, quota, and model choice by provider and repo.
- Inspect plans, diffs, PRs, terminal output, artifacts, and sources.
- Keep provider auth local; Continuum reads the tools you already use.

### Objection Handling

"Is this a cloud IDE?"

No. Continuum is local-first. Your Mac runs the daemon and provider runtimes; iPhone and Watch are paired control surfaces.

"Does this replace Cursor or Claude Code?"

No. It coordinates the tools you already use, and adds mobile control, usage visibility, and cross-provider workflow.

"Is it secure?"

The right answer for launch is specific: sandboxed Release builds, read-only provider directory access where needed, pairing tokens, Tailscale/loopback restrictions, local-first auth, and a published security model. Do not hand-wave here.

"Can I use it without Tailscale?"

For beta, assume Tailscale/MagicDNS is the easiest supported path. Broaden only after onboarding is simple and tested.

## Launch Readiness Gates

### Gate 0 - Truth Cleanup

Must be completed before any public announcement:

- Sync README version with `VERSION` and `apple/project.yml`.
- Remove or fix stale Open Design references in README/docs.
- Decide whether repo is proprietary or open-source; add LICENSE or avoid "open-source" copy.
- Add `SECURITY.md` and privacy/trust page.
- Add public "What Continuum reads locally" doc.
- Fix or document the updater tag naming contract (`vX.Y.Z-mac` vs `vX.Y.Z-buildN`).
- Confirm GitHub Release artifact names match install docs.
- Add a single "known limitations" page with Cursor chat, Linux, TestFlight, notifications, and Tailscale caveats.

### Gate 1 - Mac Beta

Public beta can start when:

- DMG build installs on a clean Mac.
- First launch instructions are accurate for signing/notarization state.
- Claude, Codex, Gemini/Antigravity, OpenCode, and Cursor capability matrix is correct.
- Pairing QR works with a real iPhone over Tailscale/MagicDNS.
- At least one real coding session can be launched, approved, inspected, and interrupted.
- Usage tab shows plausible provider data and stale/estimated states are clearly labeled.
- Security/privacy docs are linked from README and release notes.

### Gate 2 - Mobile Beta / TestFlight

Start TestFlight only when:

- Paid Apple Developer Program is active.
- App Store Connect API key and Fastlane lane are proven.
- iCloud/App Groups/Watch entitlements are validated on physical devices.
- Review notes explain paired Mac dependency and provide a demo/review path.
- App Store screenshots and preview videos show real app UI, not placeholders.
- Privacy nutrition labels match actual local/network data behavior.
- Apple review guideline 2.2/2.3 risk is handled: beta goes through TestFlight and metadata accurately reflects the core experience.

### Gate 3 - Public App Store

Submit only after:

- Activation from fresh install to first successful mobile-controlled session is under 10 minutes for a developer user.
- Pairing failure states are comprehensible.
- Tailscale/MagicDNS setup is documented or replaced by simpler transport.
- Long transcript mobile performance is validated.
- Support path exists.
- Crash/reporting policy is decided.

### Gate 4 - Linux

Do not market Linux as generally available until:

- `clawdmeterd` is not a skeleton.
- Linux desktop app opens real UI.
- AppImage and `.deb` scripts build artifacts without stub escape hatches.
- Ubuntu 24.04 and Zorin VM QA checklist is green.
- Install docs match actual release assets.

## Distribution Strategy

### Phase 1 - Private Alpha

Audience:

- 10 to 25 known coding-agent power users.
- People who can tolerate DMG friction and give precise feedback.

Goal:

- Validate activation, not growth.

Offer:

- "I built a local-first iPhone/Watch control plane for coding agents. Want to try it against your real Claude/Codex/Cursor/OpenCode setup?"

Assets:

- One install doc.
- One security/privacy doc.
- One "send me logs" support doc.
- One 90-second demo video.

Success:

- 10 installs.
- 7 pair iPhone.
- 5 launch or resume a real session.
- 3 approve/interrupt from mobile.
- 3 provide testimonial-quality feedback.

### Phase 2 - Public Mac Beta

Channels:

- GitHub Releases.
- Personal site / landing page.
- X/Twitter build thread.
- Hacker News "Show HN" only when onboarding is solid.
- Reddit only in high-signal communities, with demo-first posts.
- Discord/Slack communities for agent tooling.

Offer:

- Free beta.
- Invite users to a feedback channel.
- Strong caveats: Mac-first, iPhone companion, Tailscale recommended, Linux experimental.

CTA:

- "Download Mac beta"
- "Join TestFlight waitlist"
- "Watch the 90-second demo"

### Phase 3 - TestFlight Beta

Channels:

- Waitlist from Phase 2.
- App Store Connect/TestFlight.
- Follow-up demos focused on iPhone/Watch.

Goal:

- Prove App Store reviewability and mobile activation.

### Phase 4 - App Store Launch

Launch only after a retention signal:

- At least 40 percent of activated users use mobile control more than once in week 1.
- At least 25 percent create or resume more than one session.
- Crash-free sessions and pairing success are acceptable.

### Phase 5 - Category Expansion

Add:

- Sparkle/notarized auto-update.
- Public roadmap.
- Open-source or source-available posture if chosen.
- Linux public beta.
- Team/multi-Mac workflows.
- Integrations/content around OpenCode, Cursor, Claude Code, Codex, Gemini.

## Pricing And Packaging

Current recommendation:

- Beta: free.
- Public V1: free Mac beta + optional paid "Pro" later.
- Avoid subscriptions until App Store/TestFlight, trust docs, and retention are proven.

Potential paid packages:

1. Personal Pro, $12-20/month or one-time annual license.
   - Unlimited paired devices.
   - Advanced cost analytics.
   - Historical search.
   - Multi-provider broadcast.
   - Priority provider adapters.
2. Supporter license.
   - For early believers if open-source/source-available.
3. Team later.
   - Multi-Mac, shared dashboards, policy controls, audit logs.

Do not gate the first aha moment behind payment. The aha moment is mobile approval/control.

## Activation Design

### First-Run Flow

Target path:

1. Install Mac app.
2. Detect provider CLIs/auth state.
3. Show provider readiness matrix.
4. Ask user to pair iPhone.
5. Show QR.
6. iPhone confirms Mac.
7. Start demo-safe session or pick existing repo.
8. Send one prompt.
9. Trigger plan approval.
10. Approve from iPhone or Watch.

### Activation Metric

Activated user:

> User pairs iPhone and successfully sends, approves, interrupts, or resumes a real session controlled by the Mac.

Secondary activation:

> User views provider usage/cost by repo and changes model/effort based on the estimate.

### Onboarding Risks To Address

- Tailscale/MagicDNS setup complexity.
- App Transport Security/TLS edge cases.
- Pairing trust: user needs to know which Mac they are pairing.
- Provider auth prompts and Keychain permissions.
- Difference between Mac-running and phone-controlling.
- Cursor/OpenCode/Gemini capability differences.
- Watch voice reply not implemented.
- Regular notification/APNS limitations.

## ASO Strategy

ASO is not just keywords. For Continuum, conversion will be driven by screenshots that prove the mobile workflow. Apple explicitly recommends screenshots and previews show the app in use, with the first 1-3 screenshots carrying the core value in search results.

### App Store Product Page

Possible app name:

- Continuum

Subtitle options, 30 chars max:

- Mobile AI coding control
- AI agent IDE companion
- Control coding agents
- AI coding from your phone

Recommended first subtitle:

> Control coding agents

It is clear, keyword-bearing, and does not overclaim full IDE parity.

Promotional text:

> Start, monitor, compare, and approve local coding-agent sessions from iPhone and Watch.

Short description opening sentence:

> Continuum pairs with your Mac to control local coding agents from iPhone and Watch.

Feature bullets:

- Start and resume Claude, Codex, Gemini/Antigravity, OpenCode, and Cursor sessions from your Mac.
- Approve plans, inspect diffs, and interrupt work from iPhone or Watch.
- Compare model responses with broadcast chat.
- Track quota, usage, and estimated cost by provider and repo.
- Keep provider auth local to your machine.

### Screenshot Set

Default App Store set:

1. "Start a coding session from iPhone"
   - New session sheet: repo, agent, model, effort, preflight.
2. "Approve plans from your wrist"
   - Watch plan approval.
3. "Inspect the work before it lands"
   - iPhone session detail with Plan/Diff/PR/Terminal tabs.
4. "Compare Claude, Codex, and Gemini"
   - Broadcast chat.
5. "Know what each model costs"
   - Usage/cost analytics.
6. "Pair with your Mac"
   - QR pairing and trusted Mac copy.

Mac App Store or website screenshot set:

1. Mac Code workbench full window.
2. Mac Chat broadcast comparison.
3. Usage dashboard with provider rows.
4. Settings Providers readiness.
5. iPhone paired overlay.

### App Preview Video

30-second structure:

- 0-3s: iPhone opens Continuum, paired to Mac.
- 3-8s: start a session with model/effort.
- 8-13s: Mac workbench shows agent running.
- 13-18s: Watch/iPhone approval appears.
- 18-24s: inspect diff/terminal.
- 24-30s: cost/usage and tagline.

Use real device captures. Avoid fake demo claims.

### Product Page Experiments

Use Apple's Product Page Optimization after baseline traffic exists:

- Test 1: iPhone-first screenshot vs Mac-first screenshot.
- Test 2: Watch approval screenshot vs broadcast chat screenshot.
- Test 3: cost/quota copy vs control/approval copy.

Use Apple's Custom Product Pages for segments:

- CPP 1: "Claude Code users"
- CPP 2: "Codex users"
- CPP 3: "Cursor/OpenCode users"
- CPP 4: "Mobile approval workflow"
- CPP 5: "Model cost optimization"

Each page should vary screenshots/promotional text and deep link to the relevant onboarding path where possible.

### Keyword Clusters

Primary:

- AI coding agent
- coding agent
- Claude Code
- Codex
- Cursor
- OpenCode
- mobile IDE
- AI IDE
- developer tools
- code assistant

Secondary:

- pair Mac iPhone
- AI code review
- terminal assistant
- model cost tracker
- token usage
- plan approval
- coding from phone

Be careful with third-party trademarks. Use accurate compatibility phrasing rather than implying affiliation.

## SEO Strategy

SEO goal:

> Own the emerging query space around mobile control for coding agents, local coding-agent dashboards, model cost optimization, and provider comparison workflows.

### Site Architecture

Recommended pages:

- `/`
  - Product landing page.
- `/download`
  - Mac beta download and install.
- `/testflight`
  - iPhone/Watch waitlist.
- `/security`
  - What Continuum reads, stores, and sends.
- `/docs/pairing`
  - Pair iPhone with Mac.
- `/docs/providers/claude-code`
- `/docs/providers/codex`
- `/docs/providers/gemini-antigravity`
- `/docs/providers/opencode`
- `/docs/providers/cursor`
- `/docs/model-costs`
  - Pricing, estimates, billing confidence.
- `/compare/cursor`
- `/compare/opencode`
- `/compare/claude-code`
- `/blog`

### Search Intent Clusters

Bottom of funnel:

- "control Claude Code from iPhone"
- "Claude Code iPhone app"
- "Codex mobile app"
- "OpenCode iOS"
- "Cursor agent CLI usage"
- "AI coding agent cost tracker"
- "Claude Code usage dashboard"

Middle of funnel:

- "best AI coding agent workflow"
- "Claude Code vs Codex"
- "OpenCode vs Cursor"
- "how to monitor AI coding agents"
- "coding agent plan approval"
- "AI coding agent worktree workflow"

Top of funnel:

- "mobile IDE for AI coding"
- "AI coding agents on phone"
- "agentic coding workflow"
- "developer productivity with coding agents"

### Content Pillars

1. Mobile control:
   - "How to approve Claude Code plans from your iPhone"
   - "Why coding agents need a phone control plane"
2. Model optimization:
   - "How to choose model effort before starting a coding-agent task"
   - "The hidden cost of broadcasting prompts to multiple agents"
3. Provider workflows:
   - "Claude Code, Codex, Gemini, OpenCode, Cursor: what each is good at"
   - "Why Continuum integrates OpenCode instead of forking it"
4. Trust/local-first:
   - "What Continuum reads from your Mac"
   - "Local-first AI coding tools: what should stay on-device"
5. Release/build logs:
   - "Building a mobile-first IDE on SwiftUI"
   - "Designing a paired Mac/iPhone agent daemon"

### SEO Execution Rules

Follow Google's fundamentals:

- Make each page useful to real users first.
- Use descriptive URLs.
- Keep pages crawlable and not dependent on hidden JS state.
- Use unique titles and meta descriptions.
- Put high-quality screenshots near relevant text.
- Add descriptive alt text.
- Interlink docs, provider pages, and comparisons.
- Use canonical URLs.
- Add `SoftwareApplication`, `FAQPage`, and `VideoObject` structured data where appropriate.

## Social And Community Strategy

### Core Social Loops

Loop 1: Demo clip -> waitlist/download -> user feedback -> build-in-public fix -> demo clip.

Loop 2: Provider-specific guide -> community discussion -> compatibility feedback -> provider page update.

Loop 3: Cost/benchmark insight -> model optimization content -> developer trust -> install.

### Content Formats

X/Twitter:

- 30-90 second clips.
- Build logs.
- Before/after session workflows.
- Provider-specific findings.
- "I thought this would be easy; here is the weird part" threads.

Hacker News:

- Only post when install and onboarding are strong.
- Title idea: "Show HN: Continuum - control local coding agents from iPhone and Watch"
- Avoid vague AI hype; lead with local-first, Mac daemon, iPhone/Watch control, provider support, and limitations.

Reddit:

- Use demo-first posts in relevant dev communities.
- Avoid spammy launch copy.
- Ask for workflow feedback, not upvotes.

YouTube / Shorts:

- "Approve a coding-agent plan from Apple Watch"
- "Compare Claude, Codex, Gemini in one prompt"
- "What my AI coding agents cost this week"
- "Starting a Cursor/Claude/Codex session from iPhone"

LinkedIn:

- Use for broader "future of developer tools" essays only after product demos are crisp.

Discord/Slack:

- Target small, high-signal dev/tool communities.
- Offer beta access in exchange for detailed logs/feedback.

### Launch Thread Template

Post 1:

> I built Continuum because my coding agents kept running while I was away from the Mac.
>
> It pairs a native Mac workbench with iPhone and Watch so you can start sessions, approve plans, inspect diffs, and track model cost from your pocket.

Post 2:

> The Mac still does the real work: Claude/Codex/Gemini/OpenCode/Cursor runtimes, local auth, tmux/sidecars, repo context, usage parsing.
>
> The phone is the control plane: approve, interrupt, inspect, compare.

Post 3:

> The aha moment: an agent asks for plan approval, your Watch taps you, you approve, and the run continues before you are back at the desk.

Post 4:

> It is early. Mac DMG beta first; TestFlight next; Linux later. I am keeping the limitations public because this touches local dev machines and should earn trust the hard way.

CTA:

> Want to try it on your own coding-agent setup? Mac beta / TestFlight waitlist: [link]

## Book-Derived Strategy Principles

The strategy applies these durable frameworks without copying or quoting them:

- Positioning: define the competitive alternative, unique attributes, value, users who care, and market category.
- Crossing the Chasm: start with a narrow beachhead of power users, not the whole developer market.
- Category design: name the new problem - coding-agent sprawl - and make Continuum the control plane.
- Product-led growth: first value must happen quickly, before payment or heavy setup.
- Jobs to be Done: focus on "keep my agent moving while I am away from my Mac."
- Demand-side sales: understand switching moments, anxieties, and habits from existing CLI/IDE workflows.
- Traction/channel testing: run small channel experiments with measurable activation, not vanity reach.
- StoryBrand / Made to Stick: keep the story concrete, memorable, and visible in one screenshot.
- Hooked / habit loops: notifications and approvals must lead to useful action, not noise.
- Product-led SEO: build pages from real user questions and workflow proof.
- They Ask, You Answer: publish direct answers about security, provider support, limitations, pricing, and setup.
- Hacking Growth: instrument activation, run weekly experiments, and double down on the one channel with real conversion.

## Model Optimization GTM

This is a major differentiator. Most AI coding tools sell "smarter model." Continuum can sell "right model, right effort, right cost, right confidence."

### Product Story

- Model catalog includes provider, model, context window, badges, recommended use, effort support.
- Reasoning effort is explicit.
- Preflight estimates cost and cap impact.
- Usage status can warn during work.
- Billing confidence can be provider-reported, locally priced, estimated, or unavailable.

### Marketing Hooks

- "Stop burning Opus on chores."
- "Know the cost before you send."
- "Use expensive models where they matter."
- "Compare answers, then continue with the winner."
- "Your coding-agent spend by repo, not vibes."

### Content Ideas

- "A practical guide to choosing Claude/Codex/Gemini effort levels"
- "When to broadcast to multiple agents and when not to"
- "How much did this coding task actually cost?"
- "The model router I wanted in every coding IDE"
- "Why cost confidence matters more than a fake dollar number"

### Product Backlog To Strengthen This Claim

- Surface pricing snapshot date in UI/docs.
- Add "unknown model" education in the usage UI.
- Add historical Cursor rollups or explicitly mark Cursor as live-period only.
- Add exportable weekly cost summary.
- Add provider/model comparison report from broadcast sessions.

## Competitive Positioning

### Against Cursor

Cursor is a primary IDE. Continuum is a local-first control plane over multiple coding-agent runtimes, including Cursor code sessions where supported.

Use:

- "Works alongside Cursor."
- "Adds mobile control and cross-provider visibility."

Avoid:

- "Cursor replacement."

### Against OpenCode

OpenCode is a powerful open-source coding agent with server/client architecture. Continuum should integrate it as one provider/runtime, not fork or replace it.

Use:

- "Bring OpenCode into a native Mac/iPhone/Watch workflow."

Avoid:

- "OpenCode but mobile."

### Against Claude Code / Codex CLI

Claude Code and Codex are agent runtimes. Continuum is the cockpit around them.

Use:

- "Keep using the official tools; add mobile control, usage, and session visibility."

### Against Conductor / cmux-style workbenches

Those are workbench/session managers. Continuum's wedge is native Apple-device control, usage economics, and multi-provider mobile approvals.

Use:

- "A native paired-device control plane, not just another desktop session list."

## Website Plan

### Homepage

First viewport:

- H1: "Your coding agents, in your pocket."
- Subhead: "Run local agent sessions on your Mac, then approve plans, inspect diffs, compare models, and track usage from iPhone and Watch."
- Visual: real screenshot or short looping video of iPhone approval + Mac workbench.
- CTA: "Download Mac beta" and "Join TestFlight waitlist."

Sections:

1. The mobile approval workflow.
2. Mac is the source of truth.
3. Providers and capability matrix.
4. Usage and model cost.
5. Security/local-first.
6. Roadmap and limitations.

### Provider Capability Matrix

Columns:

- Provider
- Launch session
- Resume
- Chat
- Code session
- Plan mode
- Model picker
- Effort
- Usage/cost
- Mobile support
- Caveats

Rows:

- Claude
- Codex CLI
- Codex SDK
- Gemini/Antigravity
- OpenCode
- Cursor

This matrix is essential. It converts limitations into trust.

### Security Page

Must explain:

- What files are read.
- What data stays local.
- What is sent over the paired Mac/iPhone connection.
- How pairing tokens work at a high level.
- Why Tailscale/MagicDNS is recommended.
- What sandboxed Release builds can access.
- How to revoke access.
- How logs are handled.

## App Store / Review Risk Notes

Apple review and metadata risks:

- Metadata must accurately reflect the app's core experience.
- Screenshots should show the app in use, not title art or fake splash screens.
- Beta distribution belongs in TestFlight, not App Store.
- Reviewers need a functional way to evaluate the paired Mac dependency.
- Privacy information must match actual data collection/access.
- Any third-party provider names must be compatibility claims, not affiliation claims.

Review notes should include:

- "This app pairs with the companion Mac app to control local coding-agent sessions."
- Demo Mac app/build instructions or reviewer-accessible demo mode.
- Test account or local demo workflow if provider auth is unavailable.
- Explanation of network/local pairing requirements.

## Metrics

### North Star

Weekly mobile-controlled coding-agent sessions.

Definition:

> A session where the user performs at least one meaningful control action from iPhone or Watch: start, approve, interrupt, send, resume, inspect diff/PR/terminal/artifact.

### Activation Metrics

- Mac app installed.
- Provider detected.
- iPhone paired.
- First session started/resumed.
- First mobile command succeeds.
- First plan approved from mobile.
- First usage/cost view seen.

### Retention Metrics

- Week 1: second session.
- Week 1: second mobile command.
- Week 2: 3+ sessions controlled.
- Week 4: recurring usage/approval behavior.

### Channel Metrics

- Landing page visit to download.
- Download to first launch.
- First launch to paired iPhone.
- Paired iPhone to first mobile command.
- Waitlist to TestFlight install.
- TestFlight install to activated user.

### Quality Metrics

- Pairing success rate.
- Command receipt success rate.
- Time from session needing approval to mobile approval.
- Crash-free sessions.
- Provider readiness detection accuracy.
- Support tickets per activated user.

## 90-Day Execution Plan

### Week 1 - Truth And Trust

- Sync version numbers in README/VERSION/project/release docs.
- Remove stale Design/Open Design claims.
- Create provider capability matrix.
- Create `SECURITY.md`.
- Create privacy/local-data page.
- Create known limitations page.
- Fix release tag/updater mismatch or document exact tag convention.
- Decide license/open-source posture.

### Week 2 - Demo And Onboarding

- Record 90-second Mac+iPhone+Watch demo.
- Record 30-second App Store-style preview.
- Write "pair your iPhone" guide.
- Write "first session" guide.
- Build launch landing page.
- Build waitlist/TestFlight form.
- Run clean-Mac install rehearsal.

### Week 3 - Private Alpha

- Invite 10-25 users.
- Watch 5 live onboarding calls.
- Measure activation steps manually.
- Collect top 10 friction points.
- Fix only activation blockers.
- Publish one build log with limitations.

### Week 4 - Public Mac Beta Prep

- Prepare GitHub Release.
- Publish install/security/provider docs.
- Create support channel.
- Create short launch thread and demo clips.
- Prepare HN/Reddit copy but hold until beta users activate.

### Weeks 5-6 - Public Mac Beta

- Launch Mac beta.
- Run daily support/feedback triage.
- Ship two fast patch releases max per week.
- Publish provider-specific docs.
- Start SEO pages for Claude/Codex/Gemini/OpenCode/Cursor.

### Weeks 7-8 - TestFlight

- Complete paid Apple Developer setup.
- Prove Fastlane TestFlight lane.
- Validate iPhone/Watch entitlements on physical devices.
- Prepare App Store screenshots and preview.
- Submit TestFlight build.
- Invite waitlist in waves.

### Weeks 9-10 - ASO/SEO Experiments

- Publish 5 core SEO pages.
- Publish 3 provider comparison articles.
- Add Search Console.
- Add analytics events for activation funnel.
- Build App Store product page variants.
- Prepare custom product pages for provider-specific campaigns.

### Weeks 11-12 - Public App Store Decision

- Review activation and retention.
- Fix largest mobile reliability issue.
- Decide public App Store launch vs continued TestFlight.
- Prepare Show HN only if activation is proven.
- Draft launch changelog and roadmap.

## Weekly Operating Cadence

Monday:

- Review activation metrics and support issues.
- Pick one growth experiment and one activation fix.

Tuesday-Wednesday:

- Ship product/onboarding fix.
- Publish one useful doc or article.

Thursday:

- Record demo clip.
- Talk to 2 users.

Friday:

- Release patch if needed.
- Write weekly public build note.
- Update known limitations.

## Immediate Checklist

High priority:

- [ ] Sync README version with `VERSION` and `apple/project.yml`.
- [ ] Add `docs/security.md`.
- [ ] Add `docs/provider-capability-matrix.md`.
- [ ] Add `docs/known-limitations.md`.
- [ ] Fix/update GitHub Release tag parser contract.
- [ ] Create landing page H1, subhead, screenshots, CTA.
- [ ] Record iPhone start-session demo.
- [ ] Record Watch plan-approval demo.
- [ ] Create private alpha invite list.
- [ ] Add activation event checklist.

Medium priority:

- [ ] Add pricing snapshot date to UI/docs.
- [ ] Add App Store screenshot set.
- [ ] Add TestFlight review notes.
- [ ] Add Search Console and sitemap.
- [ ] Create provider SEO pages.
- [ ] Create support template for pairing failures.
- [ ] Validate clean Mac install.

Do later:

- [ ] Linux public launch.
- [ ] Sparkle auto-update.
- [ ] Team/multi-Mac.
- [ ] Android.
- [ ] Enterprise positioning.

## Source Notes

### Local Code Evidence

- Product overview and surfaces: `README.md`
- Version source: `VERSION`, `apple/project.yml`, `CHANGELOG.md`
- Mac root: `apple/ClawdmeterMac/Tahoe/MacRootView.swift`
- Mac Code workbench: `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift`
- Mac Chat V2: `apple/ClawdmeterMac/Workspace/ChatV2/MacChatV2View.swift`
- iOS root: `apple/ClawdmeteriOS/Tahoe/IOSRootView.swift`
- iOS new session: `apple/ClawdmeteriOS/NewSessionSheet.swift`
- iOS session detail: `apple/ClawdmeteriOS/Tahoe/IOSSessionDetailView.swift`
- iOS outbox: `apple/ClawdmeteriOS/AgentControl/MobileCommandOutbox.swift`
- Watch sessions/approval: `apple/ClawdmeterWatch/SessionsListView.swift`, `apple/ClawdmeterWatch/PlanApprovalView.swift`
- Provider/runtime/model catalog: `apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/Protocol.swift`
- Usage history: `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/UsageHistoryLoader.swift`
- Pricing: `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/Pricing.swift`
- Cursor usage: `apple/ClawdmeterShared/Sources/ClawdmeterShared/Sources/CursorSource.swift`
- OpenCode research: `docs/opencode-research-2026-05-22.md`
- Release pipeline: `apple/fastlane/Fastfile`, `apple/fastlane/Appfile`
- Follow-up/launch risks: `TODOS.md`

### External Platform Sources

- [Apple product page guidance](https://developer.apple.com/app-store/product-page/)
- [Apple product page optimization](https://developer.apple.com/app-store/product-page-optimization/)
- [Apple custom product pages](https://developer.apple.com/app-store/custom-product-pages/)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [App Store Connect Analytics dashboard](https://developer.apple.com/help/app-store-connect-analytics/overview/analytics-dashboard)
- [Google Play custom store listings](https://support.google.com/googleplay/android-developer/answer/9867158)
- [Google Play store listing experiments](https://play.google.com/console/about/store-listing-experiments/)
- [Google SEO Starter Guide](https://developers.google.com/search/docs/fundamentals/seo-starter-guide)
- [Android core app quality, for future Android planning only](https://developer.android.com/docs/quality-guidelines/core-app-quality)
