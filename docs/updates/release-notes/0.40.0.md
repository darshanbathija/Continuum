# Continuum 0.40.0

Spawn mode gets a settings home and live resizing, plus a redesigned new-session box and Code-tab polish.

## New

- **Settings → Spawn.** A new Spawn section in Settings lets you set your default agent and default session count and toggle the spawn button — and the spawn button now carries a gear that deep-links straight to it. (#462)
- **Resize a spawn on the fly.** The spawn-grid header gains a 4 / 6 / 8 toggle so you can grow or shrink an open spawn in place — growing fills the new tiles with your dominant agent, shrinking opens a fresh grid without killing any live sessions. (#460)
- **Redesigned new-session box.** The empty-state composer is now a single Codex-style input with device and account chips, replacing the old bordered panel and inline repo picker. (#463)

## Fixes

- **Spawn terminals line up again.** Fixed spawn-grid terminals that rendered misaligned because the PTY width was stuck at 120 columns instead of matching the laid-out tile. (#464)

## Polish

- **Provider favicon in the Code tab.** Code tabs now show the provider's favicon and collapse a redundant chat header for a cleaner, more compact strip. (#461)
- **More responsive menu-bar controls.** Menu-bar popover controls gained a hover fill and the pointing-hand cursor. (#465)

Ships build 244 for Mac (signed Sparkle feed), with iOS/watchOS to TestFlight.
