# Continuum 0.39.0

On-device voice transcription arrives, plus a round of Spawn-mode and Code-tab improvements.

## New

- **Parakeet local speech-to-text.** A new on-device transcription engine (NVIDIA Parakeet) joins WhisperKit, with model "tradeoff cards" in Settings → Voice that compare quality against speed so you can pick the right model for your machine. (#459)
- **Start sessions straight from the spawn grid.** Empty spawn-grid cells now show a "Start New Session" button, so you can refill a closed tile without reopening the config sheet. (#449)
- **Smarter spawn "+".** When the grid is full, "+" now auto-debits a slot from the default agent instead of doing nothing. (#455)
- **Spawn 1 or 2 sessions.** The session-count picker now offers 1 and 2, alongside 4 / 6 / 8. (#458)
- **Editable workspace rename.** Renaming a workspace opens a proper editable sheet with an "Also rename branch" toggle — relabel the workspace while keeping an open PR's branch name intact. (#453)
- **Live harness reconfigure.** Change a harness agent's model, effort, or permission mode mid-session and it reconfigures in place instead of erroring out. (#457)

## Fixes

- **Recover a stuck provider login from chat.** In-chat provider login recovery lets you re-authenticate without leaving the conversation. (#446)
- **Spawn selection border follows your click.** The tile selection border now tracks the tile you actually clicked, even after the grid reflows. (#448)

## Polish

- **More responsive controls.** Sidebar and titlebar buttons gained hover + click feedback, and composer pickers show the pointing-hand cursor. (#451, #454)
- **Roomier rows and a clearer tab.** Code sidebar worktree rows are taller and easier to hit, and the "Term" tab is now labeled "Terminal" on Mac and iOS. (#452, #450)
- **Consistent chat model pill.** The chat model pill now matches the Code composer's pill styling. (#456)

Ships build 243 for Mac (signed Sparkle feed), with iOS/watchOS to TestFlight.
