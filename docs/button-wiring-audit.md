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

1. **Phase A — iOS low-hanging** (this branch):
   - Wire SessionDetail plan-halo Approve & Refine (#1, #2)
   - Wire LiveView gear → Settings sheet (#5)
   - Wire LiveView refresh button (#4)
   - Wire AnalyticsView to `fetchAnalytics()` (#6)
   - Wire ChatView reply-copy (#7)
   - Wire ChatView Pick winner (#8) — IF an A/B `groupId` is reachable; otherwise defer
   - Remove/hide ChatView Broadcast toggle if not wired (decorative cleanup)
   - Either wire IOSPairingView or delete it (#10)

2. **Phase B — Mac low-hanging** (this branch):
   - Wire MenubarPopover "Open dashboard" (#11)
   - Wire MenubarPopover "Sync iPhone" (#12)
   - Inject `AppRuntime` into Settings + Usage views and wire auto-revive (#13, #14)
   - Wire CodeView per-repo `+` (#15)
   - Wire CodeView ReviewPR "Open PR on GitHub" — `NSWorkspace.open`

3. **Phase C — Mac high-effort** (defer to follow-up branch):
   - Mac chat send pipeline (new broadcast client wire)
   - Mac CodeView plan approval (new registry method + daemon round-trip)
   - Mac CodeView composer send

4. **Phase D — Tahoe ChatView composer rebuild** (follow-up):
   - Make iOS ChatView consume real `client.chatSessions` instead of demo
   - Add a real `TextField` to the composer
   - Wire send to `createChatSession` + `sendPrompt` OR `postComposeDraft`
