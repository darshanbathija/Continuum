# Continuum 0.42.0

Per-project icons, livelier working indicators, and a round of Code-sidebar polish.

## New

- **Per-project emoji & icon picker.** Click a project's monogram in the Code sidebar to assign it an emoji or a custom image, so your projects are easier to tell apart at a glance. (#484)
- **Livelier "working" indicators.** Chat and Code tabs now show a steady data-stream indicator with a live elapsed readout while an agent is working, replacing the old pulsing dots. (#486)
- **Active-branch data-stream cable.** Working-branch rows in the sidebar render a subtle live "cable" animation while a session is active on that worktree. (#487)

## Changed

- **Calmer Code sidebar repo headers.** The disclosure chevron now appears only on hover (Finder-style), the gear and "+" show a pointing-hand cursor, and the Spawn "+" stays visible while its settings gear slides in beside it. (#479, #481, #482)
- **Quieter tab strip.** Removed the green live-status dot from the Code-tab workspace tab strip. (#480)
- **Tidier "Projects" header.** Added leading padding so the header aligns with the content below it. (#485)

## Fixes

- **Update prompts stay put.** App-update status now stays in the top-right popover instead of taking over the screen with a center overlay. (#483)

Ships build 247 for Mac (signed Sparkle feed with binary deltas), with iOS/watchOS to TestFlight.
