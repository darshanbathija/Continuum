# Continuum 0.31.12

- Fixes OpenCode replies never rendering in the Code tab on opencode 1.16+: the live SSE path now speaks the current event vocabulary, subscribes per project directory, disables response compression on the stream, and dispatches complete events instead of waiting on frame terminators that never arrive.
- Adds Claude Fable 5 to the Chat and Code model pickers — "Fable 5 (1M)" and "Fable 5", with Fable 5 (1M) as the new default Claude model.
- Prices Fable 5 usage in the Usage tab at launch rates ($10/M input, $50/M output, $1/M cache read). Previously-cached Fable days re-price automatically on next load instead of showing $0.
- Restores accessibility identifiers on the center-header controls (transcript density, More actions, checkpoint flows) that a container identifier had overridden.
- Repo settings → "New session here" opens the full session launcher again; instant quick-spawn stays on the adjacent + button.
- Every selectable Code provider — Claude, Codex, Gemini/Antigravity, Cursor, OpenCode, Grok — now has a verified live end-to-end pass.
- Ships build 220 for the Mac app with a signed Sparkle update feed.
