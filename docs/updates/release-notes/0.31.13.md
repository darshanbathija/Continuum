# Continuum 0.31.13

- Fixes a session getting stuck on "Connecting to Claude" after picking another provider's model: cross-provider picks now open a sibling tab for that provider in the same worktree instead of pointing the running session at a model it can't load.
- Action feedback (permission mode, model, mode switches) now appears the moment you click — not seconds later after the session respawns.
- Notification bubbles moved to the bottom-right corner instead of appearing front and center.
- Ships build 221 for the Mac app with a signed Sparkle update feed.
