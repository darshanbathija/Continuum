# Continuum 0.38.1

Small Code-tab cleanups: a tidier review pane and the transcript-density control moved somewhere more sensible.

## Fixes

- **Cleaner collapsed review pane.** When you collapse the right-hand review pane, its rail now hides entirely instead of leaving a thin strip behind. Re-open it from the titlebar button or the keyboard shortcut. (#445)
- **Simpler review-pane tabs.** Removed the Source tab from the Code review pane. (#444)
- **Transcript density lives in Settings now.** The transcript-density picker moved out of the Code header into Settings → Visual, so the header stays focused and the setting persists in one place. (#447)

Ships build 242 for Mac (signed Sparkle feed), with iOS/watchOS to TestFlight.
