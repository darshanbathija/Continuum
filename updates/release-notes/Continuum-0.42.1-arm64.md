# Continuum 0.42.1

A focused round of fixes across spawn mode, the composer, and updates, plus a simpler voice-model picker and second-device onboarding.

## New

- **Simpler voice-model picker.** Settings → Voice now shows a single flat list of transcription models (Apple Speech, WhisperKit, Parakeet) instead of a separate engine selector — pick a model and the right engine is used automatically. (#491)
- **Second-device onboarding.** Settings → Devices now walks you through adding a second device (execution host) so you can run agents on another Mac. (#492)
- **Paste images into the composer.** ⌘V now pastes clipboard images (screenshots, copied files) straight into the chat composer as attachments. (#489)

## Fixes

- **Spawn mode launches the real opencode.** Spawn tiles now run your installed `opencode` TUI instead of the bundled serve helper (which rendered an empty tile); if opencode isn't installed you get an Install prompt. (#495)
- **Cleaner spawn terminals.** Fixed spawn-grid tiles that left a stranded wide "opening frame" behind after the tile reflowed to its real width. (#494)
- **Cancelling an update reverts instantly.** Cancelling an in-progress update download now snaps the popover back immediately instead of leaving a stuck progress bar. (#490)

## Polish

- **Cleaner spawn header & clickable rows.** Tidied the spawn grid header and made the sidebar spawn rows clickable across their whole width. (#493)
- **Aligned repo headers.** Code-sidebar repo header rows now match the height of the worktree/session rows beneath them. (#488)

Ships build 248 for Mac (signed Sparkle feed), with iOS/watchOS to TestFlight.
