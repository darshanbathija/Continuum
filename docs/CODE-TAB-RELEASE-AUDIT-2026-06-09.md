# Code Tab Release Audit - 2026-06-09

Scope: primary navigation `Code` tab only. Settings, Usage, menu-bar popovers, and provider settings are out of scope except where a Code-tab control opens them.

## Verification

- Unit: `SessionLauncherModelTests/test_boundComposerTreatsEmptyTranscriptAsFirstPrompt`
- Unit: `SessionLauncherModelTests/test_boundComposerTreatsExistingConversationAsFollowUp`
- Unit: `SessionLauncherModelTests/test_firstSendRecoveryIsScopedToPromotedSession`
- Unit: `SessionLauncherModelTests/test_configureProvisionalLaunchGivesSub100msFeedbackForRapidPickerToggles`
- Unit: `AgentSessionRegistryEventStoreWireTests/test_previewLaunchConfiguration_isInMemoryOnlyForFastPickerToggles`
- Unit: `WorkspaceTabsTests/test_openOrCreateWorkspaceTerminalTabSurfacesPendingTabWithin100ms`
- Unit: `WorkspaceTabsTests/test_openWorkspaceTerminalTabAllowsHarnessSessionDirectWorktreeShell`
- Unit: `AgentControlServerChatRouteTests/test_terminalAddOnHarnessSessionCreatesDirectWorktreePane`
- Unit: `TerminalPtyHostTests/test_directPtyHostStreamsInputOutputAndAppliesResize`
- UI: selected Code-tab UI suite passed 7/7: composer controls, new-session shortcut, preview/browser, rename shortcut, sidebar controls, review-pane controls, and terminal shortcut/direct-shell surface.

Note: macOS initially blocked the generated UI-test runner as damaged. Rebuilding for testing, removing quarantine/provenance attrs, and ad-hoc re-signing the generated runner made the runner valid and allowed Code-tab UI tests to execute.

## Fixes Applied

| Issue | Fix | Result |
| --- | --- | --- |
| New `+` session could open stale branch/session or leave multiple selections visible. | Optimistic sessions now reserve the city worktree path immediately and clear draft/terminal/document/outside selections before opening the provisional session. | New session selection is scoped to the newly-created provisional session. |
| Model/provider toggles while a `+` session is provisioning were too slow and could target an old session. | Provisional picker changes now use an in-memory registry preview and a pending launch config; the final daemon spawn uses the latest selected provider/model/effort. | 200 provisional picker flips stayed under the sub-100 ms per-toggle budget in unit coverage. |
| First message in a new/provisioning session could be queued as a follow-up instead of sent as the first prompt. | Bound composer send now checks transcript content; empty/meta-only transcript sends as first turn, existing user/assistant/tool content sends as follow-up. | First real prompt no longer gets stuck in the follow-up queue. |
| Provisioning trail always said `Starting Codex`. | Trail labels now use the selected provider display name. | Antigravity/Claude/Codex sessions show the correct provider while starting. |
| Send/stop control did not match Codex app reference. | Composer action is now icon-only and pinned in the bottom-right control cluster; running state shows only a circular stop button. | No live/cost/tap-to-stop text remains on the button. |
| Hover archive action did not appear for worktree rows. | Worktree rows now track hover state and show archive action for that worktree. | Hover affordance is present at the worktree/session level. |
| Archive-all was slow. | Bulk archive path writes per-session receipts but coalesces the in-memory mutation/save and schedules worktree cleanup after rows disappear. | Archive-all avoids repeated full `sessions.json` saves. |
| `Cmd+Shift+R` did not open the shared rename dialog. | Workspace shortcut layer now posts the existing rename notification, and the sidebar listens by opening the same rename alert used by context menus. | UI test verifies the rename dialog opens from Code tab. |
| Code terminal did not work for Codex/ACP-style sessions and could feel stuck while shell startup blocked visible feedback. | Code terminal availability now follows local worktree/session eligibility instead of agent `supportsTerminal`; new terminal tabs select a pending surface immediately, create explicit direct-shell panes asynchronously, and the server falls back to direct shell when no Claude PTY host exists. | Unit coverage proves pending tab feedback within 100 ms; `Cmd+Shift+T` opens a terminal tab and reaches `Terminal connected` in UI coverage. |

## Control Audit

| Surface | Control | Designed behavior | Current behavior | Status |
| --- | --- | --- | --- | --- |
| Code nav | `Code` tab | Switch dashboard into Code workspace. | UI test opens it with `Cmd+3` and clicks `dash.tab.code`. | Correct. |
| Sidebar | Search field / `Cmd+K` | Filter projects/sessions and focus from shortcut. | Existing control remains; not changed in this pass. | No regression observed. |
| Sidebar | Filter menu | Filter by status, group, sort, refresh repo list, reset filters. | Existing menu remains; not changed in this pass. | No regression observed. |
| Sidebar | Add project menu | Open local project, open GitHub project, or quick start. | Existing menu remains; not changed in this pass. | No regression observed. |
| Sidebar | Repo disclosure | Expand/collapse repo worktrees. | Existing control remains; provisional new sessions force-expand target repo. | Correct. |
| Sidebar | Repo `+` / new session | Start an optimistic worktree session in the repo. | Now reserves worktree path, clears stale selections, opens provisional session immediately. | Fixed. |
| Sidebar | Repo gear menu | New session here, archive all, archive repo, repo settings link, remove repo. | Archive-all uses the new bulk archive path; linked settings internals stay outside Code-tab release evidence. | Fixed for speed. |
| Sidebar | Worktree row | Open session/worktree; show live status. | UI tests select seeded worktree row before composer/browser assertions. | Correct. |
| Sidebar | Worktree hover archive | Archive every session in that worktree. | Hover state now reveals archive action. | Fixed. |
| Sidebar | Session row context menu | Revive, pin, unread, mute, snooze, color tag, pop out, compare, copy ID, reveal JSONL, open PR, rename, archive/unarchive, sub-chat, end. | Existing menu remains; rename shortcut now shares its dialog. | Fixed shortcut path. |
| Footer | New session / `Cmd+N` | Open the new session launcher. | Code-only UI test verifies Start button appears. | Correct. |
| Tab strip | Session tab | Switch active chat session. | Existing behavior remains. | No regression observed. |
| Tab strip | Close tab | End/close selected chat, terminal, or document tab. | Existing behavior remains. | No regression observed. |
| Tab strip | `+` menu | Open new Chat tab and expose a direct terminal for local worktree sessions. | Workspace terminal shortcut opens an immediate pending terminal tab, then promotes it to an explicit direct-shell pane; tab strip target remains covered. | Fixed. |
| Header | Transcript density menu | Switch transcript density. | Existing menu remains. | No regression observed. |
| Header | More menu | Open terminal, schedule follow-up, create/restore checkpoint, pop out, archive, end. | Terminal action now uses the same direct worktree-shell gate as the shortcut/tab path. | Fixed terminal path. |
| Queue panel | Clear | Remove all queued follow-ups. | Existing control remains. | No regression observed. |
| Queue panel | Send queued prompt | Dispatch queued draft now or after current stream. | Disabled off `currentTurnState` rather than broad session running state. | Fixed. |
| Queue panel | Delete queued prompt | Remove one queued draft. | Existing control remains. | No regression observed. |
| Checkpoint strip | Restore | Preview/restore latest checkpoint. | Existing control remains. | No regression observed. |
| Composer | Text input | Type first prompt or follow-up; supports drag/drop. | First-prompt vs follow-up decision is transcript-aware. | Fixed. |
| Composer | Attach / `Cmd+U` | Add files/images/context. | Code-only UI test verifies stable target. | Correct. |
| Composer | Model/effort chip | Change model, effort, and provider rail. | Provisioning sessions update in-memory pending launch config immediately. | Fixed for speed/correctness. |
| Composer | Permission mode chip | Switch Ask/Accept edits/Plan/Bypass. | Code-only UI test verifies stable target. | Correct. |
| Composer | Prompt history | Open saved prompt history. | Existing control remains. | No regression observed. |
| Composer | Saved prompts | Insert saved prompt or save current prompt. | Existing control remains. | No regression observed. |
| Composer | Strip ANSI paste | Paste terminal text without ANSI codes. | Existing control remains. | No regression observed. |
| Composer | Expand editor | Open larger editor. | Existing control remains. | No regression observed. |
| Composer | Mic | Toggle dictation. | Existing control remains. | No regression observed. |
| Composer | Context usage chip | Show context/usage popover. | Code-only UI test verifies stable target after selecting a session. | Correct. |
| Composer | Queue follow-up / `Option+Return` | Queue prompt while current turn streams. | Now only appears for actual streaming turn state. | Fixed. |
| Composer | Send / `Cmd+Return` | Send current draft. | Icon-only bottom-right send button; first prompt sends as first turn. | Fixed. |
| Composer | Stop / `Cmd+.` | Interrupt current streaming turn. | Icon-only bottom-right stop button; no extra text. | Fixed. |
| Pending strip | Retry | Retry failed pending send. | Existing control remains. | No regression observed. |
| Pending strip | Dismiss | Clear pending failed send. | Existing control remains. | No regression observed. |
| Turn row | Preview chip | Open detected preview URL in full-workspace Browser. | Code-only UI test verifies preview opens Browser and Back to Chat returns. | Correct. |
| Right pane rail | Plan | Show plan/todo state for the session. | Existing pane selector remains. | Not changed. |
| Right pane rail | Diff | Show repo diff; width expands for readability. | Existing pane selector remains. | Not changed. |
| Right pane rail | Sources | Show files read/grepped/globbed by the agent. | Existing pane selector remains. | Not changed. |
| Right pane rail | Artifacts | Show generated non-source artifacts. | Existing pane selector remains. | Not changed. |
| Right pane rail | Browser | Show embedded browser/preview pane. | Browser surface covered through Preview chip flow. | Correct. |
| Right pane rail | PR | Show PR state/actions. | Existing pane selector remains. | Not changed. |
| Right pane rail | Terminal | Show an inline direct PTY terminal for eligible local worktree sessions. | Uses the same terminal availability/server path as the verified Code terminal tab; terminal tabs now show pending feedback before shell spawn. | Fixed route; separate right-pane click coverage still pending. |
| Browser | Back to Chat | Exit full-workspace Browser. | Code-only UI test verifies it returns to chat. | Correct. |
| Browser | Back/forward | Navigate web history. | Existing controls remain. | No regression observed. |
| Browser | Reload/stop | Reload page or stop loading. | Existing control remains. | No regression observed. |
| Browser | URL field | Enter URL and submit. | Code-only UI test verifies stable target. | Correct. |
| Browser | Load URL | Load the URL field. | Existing control remains. | No regression observed. |
| Browser | Run command/start | Start detected/manual run profile. | Existing control remains. | No regression observed. |
| Browser | Stop run | Stop active run profile. | Existing control remains. | No regression observed. |
| Browser | Restart run | Restart run profile. | Restart button has an explicit accessibility node and is covered by the Code-tab Browser UI test. | Correct. |
| Browser | Show run output | Toggle run output preview. | Existing control remains. | No regression observed. |
| Browser | Comment cancel/add | Stage browser comment into chat context. | Existing controls remain. | No regression observed. |

## Residual Gaps

- External macOS windows interrupted one UI run; XCTest reactivated Continuum and the selected Code-tab tests still passed.
- Latency coverage now includes provisional model toggles and terminal-tab pending feedback, but not every interactive Code-tab element yet.
- The right-pane Plan/Diff/Sources/Artifacts/PR controls were inventoried but not exhaustively click-tested in this pass.
- The right-pane Terminal tab reuses the fixed direct-shell route, but the full right-pane menu/gutter Terminal click path still needs separate UI coverage.
