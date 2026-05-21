# Button wiring audit — Tahoe surfaces

Generated 2026-05-22 against `feat/button-wiring-audit` off `main@53e14a7`.

Goal: every button on every Tahoe surface either invokes a real backend
action or is removed. No decorative buttons in production.

## Totals

| Platform | Interactive controls | Wired | Demo-only | No-op |
|----------|---------------------|-------|-----------|-------|
| Mac      | 48                  | 14    | 4         | 30    |
| iOS      | 54                  | 35    | 0         | 19    |
| **Total**| **102**             | **49 (48%)** | **4 (4%)** | **49 (48%)** |

iOS reads better because `NewSessionSheet` + `PairingFlow` (carried over from
the pre-Tahoe Sessions v2 work) are fully wired. Mac is dominated by the
Chat tab being almost entirely decorative.

## Highest-leverage gaps (existing backend, dead button)

| # | Surface | Element | Backend (exists) | Effort |
|---|---------|---------|------------------|--------|
| 1 | iOS SessionDetail | Plan halo "Approve & run" | `client.approvePlan(sessionId:)` (L743) | low |
| 2 | iOS SessionDetail | Plan halo "Refine" | `client.sendPrompt(sessionId:text:)` (L204) | low |
| 3 | iOS SessionDetail | `sliders` icon (header) | `client.changeModel/changeEffort/changeMode` (L186/192/198) | medium — needs sheet UI |
| 4 | iOS LiveView | Footer refresh button | `client.refreshAll()` (L118) | low |
| 5 | iOS LiveView | Header gear icon | open existing `SettingsView` sheet | low |
| 6 | iOS AnalyticsView | Period segmented uses fixture data | `client.fetchAnalytics()` (L857) | medium — adapter needed |
| 7 | iOS ChatView | Reply "copy" icon | `UIPasteboard.general.string` | low |
| 8 | iOS ChatView | "Pick winner" button | `client.frontierPickWinner(groupId:childIndex:)` (L706) | medium — needs A/B groupId source |
| 9 | iOS ChatView | Composer send + textfield | `client.postComposeDraft(_:)` (L895) / `sendPrompt` (L204) — also needs a `TextField` | high — non-trivial UI |
| 10 | iOS PairingView | "Scan QR" + "Paste URL" + entry point | `PairingScannerView.parse(_:)` + `client.setPairing(...)` | medium — also needs nav wire |
| 11 | Mac MenubarPopover | "Open dashboard" | `NSApp.activate(ignoringOtherApps:)` + scene activation | low |
| 12 | Mac MenubarPopover | "Sync iPhone" | present existing `PairingQRPopoverContent` | low |
| 13 | Mac SettingsView | Auto-revive toggle | `claudeModel.setAutoReviveEnabled(_:)` exists | medium — view needs `AppRuntime` injection |
| 14 | Mac UsageView | Auto-revive toggle (per-provider) | same — `AppModel.setAutoReviveEnabled` | medium — view needs `AppRuntime` |
| 15 | Mac CodeView | Per-repo `+` button | `AgentSessionRegistry.create(...)` exists — needs `NewSessionMacSheet` invocation | medium |
| 16 | Mac CodeView | Plan halo "Approve & run" | needs new daemon RPC `approvePlan` on Mac registry | high — backend gap |
| 17 | Mac CodeView | Composer send (when not demo) | needs Mac-side broadcast/spawner wire | high — backend gap |
| 18 | Mac CodeView | Plan halo "Refine" / "Edit plan" | needs send-prompt API on Mac registry | high |
| 19 | Mac CodeView | Sidebar `filter` / `folderPlus` | could filter `SessionsModel.repos` / scan-root prompt | medium |

## Decorative — should be hidden or removed

| Surface | Element | Action |
|---------|---------|--------|
| iOS RootView | Titlebar `TahoeSyncChip` (status) | Already decorative pill — keep |
| iOS CodeView | Fake "search" + mic chip | Either build search or remove the chip |
| iOS ChatView | Broadcast toggle in header | Either wire to fanout or remove |
| Mac titlebar | "Updated 14s ago" Label | Either wrap in Button (refresh) or remove |
| Mac titlebar | "Sync with iPhone" / "iPhone paired" chips | Keep — purely informational |

## Out-of-scope (needs new daemon RPC or product decision)

- **Mac chat send pipeline**: requires `broadcastClient` or new `AppRuntime` chat-send API; no current backend equivalent.
- **iOS LiveView per-provider auto-revive**: `AppModel.setAutoReviveEnabled` is Mac-only today. No iOS RPC exists.
- **iOS ChatView composer**: needs a `TextField` + send pipeline; the Mac and iOS chat tabs are entirely fixture today.
- **Reply "regenerate"**: no concept of "regenerate" in any agent's wire today.
- **Mac CodeView plan approval**: Mac uses `AgentSessionRegistry` directly (not via daemon); needs a local `approvePlan` method on the registry.

## Plan for this branch

### Phase A — iOS low-hanging ✓ LANDED

- ✓ SessionDetail plan-halo Approve → `client.approvePlan(sessionId:)`
- ✓ SessionDetail plan-halo Refine → alert + `sendPrompt(...)`
- ✓ SessionDetail composer (real TextField + send button)
- ✓ SessionDetail pull-to-refresh
- ✓ LiveView gear → SettingsView sheet
- ✓ LiveView footer refresh button + pull-to-refresh
- ✓ AnalyticsView consumes `fetchAnalytics()` (was 100% demo fixture)
- ✓ AnalyticsView "sliders" → manual refresh
- ✓ Settings sheet hoisted to IOSRootView

### Phase B — Mac low-hanging ✓ LANDED

- ✓ MenubarPopover "Open dashboard" → AppDelegate.showDashboard() path
- ✓ MenubarPopover "Sync iPhone" → presents `PairingQRPopoverContent` in its own NSPopover
- ✓ Settings auto-revive toggle → fans out to every AppModel.setAutoReviveEnabled
- ✓ Settings "Reset to defaults" → `TahoeThemeStore.resetToDefaults()`
- ✓ UsageView per-provider auto-revive toggle → `AppModel.setAutoReviveEnabled(_:)`
- ✓ UsageView MenuBarCheckbox → `UserDefaults` pref key (AppDelegate observer picks it up live)
- ✓ CodeView per-repo `+` → presents NewSessionMacSheet with that repo preselected
- ✓ CodeView sidebar `folderPlus` → presents NewSessionMacSheet (no preselection)
- ✓ NewSessionMacSheet accepts `preselectedRepoKey` param

### Phase C — defer to follow-up branch

- Mac chat send pipeline (no `runtime.broadcastClient` exists)
- Mac CodeView plan approval (no daemon round-trip on Mac yet)
- Mac CodeView composer send (same)
- Mac CodeView Plan halo Refine / Edit plan
- iOS ChatView composer (no `TextField`, needs `createChatSession` + `sendPrompt`)
- iOS ChatView Pick winner (needs reachable A/B `groupId`)
- iOS PairingView (entry point doesn't exist; either route to it or delete)
- iOS LiveView per-provider auto-revive (no `setAutoRevive(provider:enabled:)` RPC)
- iOS CodeView search field
- Mac CodeView ReviewPR "Open PR on GitHub" — demo-only surface today
- Reply "regenerate" — no agent supports it on the wire today

### Phase D — Tahoe ChatView composer rebuild (separate branch)

- Make iOS + Mac ChatView consume real chat sessions instead of demo
- Add real composer TextField
- Wire send to `createChatSession` + `sendPrompt` or `postComposeDraft`

## Product decisions (2026-05-22 walkthrough)

Captured via AskUserQuestion. These lock in the scope and ordering for
the next branches.

| # | Decision | Choice | Notes |
|---|----------|--------|-------|
| D1 | Chat send pipeline | **Full broadcast + solo on both platforms** | New `runtime.broadcastClient`, per-provider streaming, real composer, history persistence, send-state UI |
| D2 | Mac Code IDE write path | **Mac as daemon client to itself** | MacRootView talks to local `AgentControlServer` via `AgentControlClient` over loopback; same code path as iOS; unifies the action surface long-term |
| D3 | iOS pairing | **IOSPairingView replaces PairingFlow** | Wire Scan QR + Paste URL buttons; route `PairingCTAButtons` + `SettingsView` to it; delete `PairingFlow.swift` |
| D4 | iOS LiveView auto-revive | **Build `setAutoRevive(provider:enabled:)` daemon RPC** | New endpoint on `AgentControlServer`, matching client method; fans out to the right `AppModel` on Mac |
| D5 | iOS CodeView search | **Build session search** | Real `TextField` + filter on repos + sessions |
| D6 | Mac titlebar | **Wire all three to real state** | `Updated Xs ago` reads `runtime.lastPolledAt`; `Sync with iPhone` becomes a button (opens QR popover when unpaired); `iPhone paired` shows real pairing state |
| D7 | Chat reply icons | **Copy + Pick winner only** | Drop refresh/share/star icons. Copy → pasteboard. Pick winner → `client.frontierPickWinner(groupId:childIndex:)` |
| D8 | Mac sidebar filter | **Build full NSMenu** | Toggles: live only / paused / by-provider / sort by last active; UserDefaults-persisted |
| D9 | Mac ReviewPane tabs | **All 5 wired (Plan + Diff + Sources + PR + Term)** | Diff = `git diff main...HEAD`; Sources = `RepoIndex` semantic; PR = `gh pr view` + `NSWorkspace.open`; Term = live tmux mirror via SwiftTerm |
| D10 | Release sequencing | **Phased PRs by surface — Code first, Chat second** | See plan below |

## Release plan (post-decisions)

### PR #23 (current branch — feat/button-wiring-audit) — Phase A + B
- Audit doc, iOS Session Detail wiring, iOS LiveView wiring, iOS Analytics
  consuming real `fetchAnalytics()`, Mac menubar dashboard + sync, Mac
  Settings auto-revive, Mac Usage per-provider toggles, Mac Code per-repo
  new-session sheets.
- **Status**: open, ready to land.

### PR #24 — `feat/mac-code-ide-complete` (Code first)
**Scope:** Mac Code IDE end-to-end. After this PR, every Mac CodeView
control reaches a real backend.
- D2: Make Mac talk to its own daemon via `AgentControlClient` loopback.
- D9 (Diff): live `git diff main...HEAD` against worktree.
- D9 (Sources): semantic search via `RepoIndex.search(query:)`.
- D9 (PR): `gh pr view` JSON; "Open PR on GitHub" → `NSWorkspace.open`.
- D9 (Term): live tmux pane mirror via `SwiftTerm` view.
- Plan halo "Approve & run" → `client.approvePlan(sessionId:)` (now on
  loopback).
- Plan halo "Refine" / "Edit plan" → `client.sendPrompt(...)` with refine UI.
- Composer Send → `client.sendPrompt(...)`; LiveTicker Stop →
  `client.interruptSession(...)`.
- D8: Mac sidebar filter menu (NSMenu w/ Live/Paused/By-provider/Sort).
- Build verification on Mac.

### PR #25 — `feat/chat-pipeline` (Chat second)
**Scope:** Full chat pipeline both platforms.
- D1: `runtime.broadcastClient` + per-provider chat session lifecycle.
- iOS ChatView real composer TextField + send via `postComposeDraft` or
  the new chat broadcast RPC.
- Mac ChatView sidebar "New chat" + history rows wired (open chat).
- D7: Copy reply (UIPasteboard/NSPasteboard) on every assistant card.
- D7: Pick winner on broadcast turns → `frontierPickWinner`.
- Drop refresh/share/star icons from the assistant card.
- Drop ChatView "Broadcast" toggle from header (mode lives in titlebar
  on Mac; iOS gets a similar pattern).
- Build verification on Mac + iOS.

### PR #26 — `feat/wiring-polish` (Polish third)
**Scope:** the remaining 4 small but high-honesty wires.
- D3: IOSPairingView replaces PairingFlow; delete the old sheet.
- D4: `setAutoRevive(provider:enabled:)` daemon RPC + iOS wire.
- D5: iOS session search field (TextField + filter).
- D6: Mac titlebar — real `Updated Xs ago`, `Sync with iPhone` button,
  `iPhone paired` reflecting real pairing state.
- Build verification on all 3 platforms.

After PR #26 lands, the audit table should read **102/102 wired** (or
explicitly removed) with zero decorative no-ops.

## Wiring deltas after Phase A + B

| Platform | Interactive | Wired | Demo-only | No-op |
|----------|------------|-------|-----------|-------|
| Mac      | 48         | 22    | 4         | 22    |
| iOS      | 54         | 47    | 0         | 7     |
| **Total**| **102**    | **69 (68%)** | **4 (4%)** | **29 (28%)** |

Wired ratio jumped from 48% → 68%. The remaining 28% are dominated by the
chat-send pipeline (no backend) and the Mac code IDE write path (needs new
daemon round-trip). Phase C planning lives at the top of this doc.
