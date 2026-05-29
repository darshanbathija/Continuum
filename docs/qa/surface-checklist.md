# Continuum (Mac) — surface QA checklist

Canonical list of every user-facing surface in the Continuum desktop app, the
behaviour expected of it, and the regression checks for bugs fixed in the
`fix/desktop-surface-audit` pass. Run alongside `tools/qa-surfaces.sh` (which
builds, tests, launches the app, and captures logs) and query errors with
`tools/clawdmeter-logs.sh 7`.

Legend: ✅ expected behaviour · 🐞 regression check (bug we fixed — must NOT recur).

---

## 1. Menu bar (status item + popover)
Files: `AppDelegate.swift`, `MenuBarGaugeView.swift`, `Tahoe/MacMenubarPopover.swift`, `PopoverView.swift`

- ✅ A 16pt gauge renders in the status bar and updates as rate-limit/usage polls land.
- ✅ Clicking the status item opens the popover; clicking away dismisses it.
- ✅ Popover shows current provider gauges + recent usage without beachballing.
- ✅ Window title in the titlebar is the app's own — never a terminal/program title.
  - 🐞 (#12) Open Code → Term, run `printf '\033]0;HIJACK\007'` (or `vim`): the app
    window title must stay put — the embedded terminal must not rename the window.

## 2. Chat tab (Chat V2 — solo + broadcast)
Files: `Workspace/ChatV2/MacChatV2View.swift`, `Workspace/Composer/ComposerInputCore.swift`

- ✅ Sidebar lists solo chats and broadcast-comparison groups, newest first; pinned on top.
- ✅ Selecting a solo chat streams the assistant reply **live**, token by token.
  - 🐞 (#2) Send a prompt and watch: the reply must grow in real time, not jump only
    when you click away/back or an unrelated refresh fires.
- ✅ Transcripts older than the in-memory window are reachable via "Load earlier messages".
  - 🐞 (S1) In a >200-message chat, scroll to top → a "Load earlier messages" control
    appears and loads older history (solo and each broadcast column).
- ✅ Scrolling a long transcript is smooth; no per-row rebuild hitches.
  - 🐞 (S2) Long chat / broadcast column scrolls without stutter (no per-row `.id`).
- ✅ Composer `@` opens the mention picker **only** at a word boundary.
  - 🐞 (#4) Type `email me at name@company` → the mention picker must NOT open.
    Type `@` after a space → it opens. Accept a mention with text after the caret →
    only the `@token` is replaced; text after it is preserved.
- ✅ Composer `/` opens the slash-command palette (unchanged).
- ✅ Sidebar relative timestamps render; scrolling the history list stays smooth.
  - 🐞 (S8/S10) No per-row formatter allocation or O(n²) regroup churn while scrolling.

## 3. Code / Sessions tab (agent workbench)
Files: `Tahoe/MacCodeShell.swift` → `Workspace/SessionWorkspaceView.swift`, `AgentControl/MacTerminalView.swift`, `Workspace/ArtifactsPane.swift`

- ✅ Sidebar groups sessions by repo; pinned/most-recent ordering; search filters.
  - 🐞 (S9) Large session list sorts/filters without lag (pin-rank precomputed).
- ✅ Chat transcript (`ChatThreadScroll`) streams live and scrolls smoothly (already on `List`).
- ✅ Find-in-transcript (⌘F): highlights matches; next/prev navigates; scrolling with
  Find open stays smooth.
  - 🐞 (S3) Open Find on a long session, type a query, scroll — no per-row full-transcript
    rescans (highlight membership is O(1) cached).
- ✅ Embedded **Terminal** streams output; survives sleep/wake and brief network drops.
  - 🐞 (#3) Open Term on a live session, sleep/wake the Mac (or bounce Wi-Fi): the terminal
    must auto-reconnect and resume output — not freeze until you switch tabs.
- ✅ **Artifacts** pane shows thumbnails of agent-written files; click → QuickLook.
  - 🐞 (#7) Rapid agent writes never show an older artifact set overwriting a newer one.
  - 🐞 (#8) Switch session A → B: artifacts shown are B's, never A's stale set.
  - 🐞 (#10) Thumbnails don't regenerate on every tick; a recycled cell never flashes
    the wrong file's preview.
- ✅ Diff / PR review panes render (Mac production path; the standalone `MacCodeView`
  prototype is **not** shipped — ignore it in QA).

## 4. Usage tab (analytics)
Files: `Tahoe/MacUsageView.swift`, `Tahoe/AnalyticsRangeAdapter.swift`, `AnalyticsView.swift`

- ✅ Spend-over-time chart + by-repo list reflect real `ccusage`-aligned numbers.
- ✅ Switching ranges (Today / 7d / 30d / 90d / All) updates the chart promptly.
  - 🐞 (S4) Range/hover changes don't allocate a `DateFormatter` per bar/tick.
  - 🐞 (S11) Bucketing reads only each bucket's day range (no full-history rescan per render).
- ✅ Totals match `ccusage daily` (ground truth) for the same window.

## 5. Settings
Files: `Tahoe/MacSettingsView.swift`, `PairingSettingsView.swift`, `DiagnosticsSettingsView.swift`, `ProvidersSettingsView.swift`

- ✅ Pairing pane shows the QR + URL; Plugins section lists detected MCP servers/plugins.
  - 🐞 (S5) Opening/scrolling the Pairing pane does NOT re-scan disk on every render
    (plugin inventory is loaded once on appear).
- ✅ Diagnostics → Audit Log lists entries with text/session filters; scrolls smoothly.
  - 🐞 (S12) Audit list uses stable per-row identity (no `id: \.offset`) — rows don't
    churn/recycle-thrash as the list grows or filters.
- ✅ Providers pane lets you configure model defaults; changes persist.

## 6. Cross-cutting: scrolling & logging
- ✅ Every long list (chat, sidebar, audit, artifacts) uses lazy/virtualized rows with
  stable identity — scrolling is smooth at 1k+ items.
- ✅ Errors are queryable after the fact: `tools/clawdmeter-logs.sh 7` shows every
  `.error`/`.fault` from subsystem `com.clawdmeter.mac` over the last 7 days.

---

### How to run
```bash
tools/qa-surfaces.sh                 # build + shared tests + launch + capture logs
RUN_MAC_TESTS=1 tools/qa-surfaces.sh # also run the Mac XCTest suite
tools/clawdmeter-logs.sh 7           # review persisted errors over the last 7 days
tools/clawdmeter-logs.sh --stream    # live error/fault tail while you click around
```
