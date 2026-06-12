# Continuum 0.35.0

Multi-account provider settings, a redesigned Providers pane, the OpenRouter provider is back, and a faster, more consistent Code tab.

- **Redesigned Settings → Providers.** Each provider now has a clean Connect/Disconnect layout, and the Skills settings tab matches the same styling for a consistent settings surface. (#383, #380)
- **Better multi-account provider settings.** Secondary Claude and Codex accounts are handled more evenly across the app, with sensible Code defaults per account and Terminal shims installed for each secondary so your shell sees the right account. (#371, #375)
- **OpenRouter is back.** The OpenRouter provider returns with distinct branding so you can route Chat and Code through it again. (#376)
- **Code tab account chip.** The Code tab now shows which account a session is running under, right beside the permission-mode control — no more guessing which subscription is being billed. (#373)
- **OpenCode Go credential import.** Saving OpenCode Go settings now imports your quota credentials straight from the browser Keychain, so the usage meters light up without manual cookie copying. (#372)
- **Cursor usage in the menu bar.** The menu-bar label now shows both Cursor Auto and API usage, and the Usage tab provider-card grid lays out cleanly for 5 and 6 cards. The redundant Monthly total row was removed. (#387, #374, #388)

## Faster + more consistent

- **Instant model and default switches.** Changing the default model in Settings and switching the model from the picker now update the model pill immediately, and the Code-tab model toggle stays in sync across the tab, header, and composer. (#368, #370, #386)
- **Check for Updates responds instantly.** The update check now answers right away from cached status instead of stalling, and the empty release-notes section is hidden in the update popover. (#369, #379)
- **Cleaner model picker.** The Code-tab model picker bottom bar and rows were simplified, and the non-functional Code-tab filter button was removed. (#389, #385)

## Fixes

- **Repo-branch tab labels.** Tabs now show a repo-branch label until a short summary arrives, so a new session is never a blank tab. (#384)
- **Worktree handling.** The worktree archive is clickable, branches sort by creation time, and Option-clicking a repo always spawns a fresh branch instead of reusing a stale diff. (#382, #378)
- **Snappier live timelines.** Live UI timelines are now bounded so long-running sessions stay responsive. (#381)
- **Cleaner app icons.** The iOS and Watch 1024×1024 app icons have their alpha channel stripped to satisfy App Store icon requirements. (#364)

Ships build 235 for Mac (signed Sparkle feed) with iOS/watchOS to TestFlight on the same build.
