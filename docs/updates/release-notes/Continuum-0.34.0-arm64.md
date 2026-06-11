# Continuum 0.34.0

OpenCode Go as a first-class provider, context window breakdown in the Code tab, and relay pairing improvements.

- **OpenCode Go provider.** Add your Go API key (from opencode.ai/zen) in Settings or onboarding to use OpenCode in Chat and Code. Pick Go models (Kimi, GLM, DeepSeek, MiniMax, Qwen) from the provider tray and model picker. An optional workspace ID and auth cookie drive the 5h / weekly / monthly quota meters on the Usage tab.
- **Context window breakdown in the Code tab.** The composer popover now shows a Cursor-style per-category breakdown (messages, MCP tools, memory files, skills, system prompt, custom agents) instead of a single session cost row. Updates live via ACP when Claude Code publishes a context_window_update event, or estimates locally otherwise.
- **Relay grant provisioning.** The relay pairing flow can now provision a grant token and install identity to authenticate relay connections from the Mac.
- **Skill plugin importer.** Import .continuum-skill bundles directly from the Skills settings pane.
- **Repo env vendor secrets importer.** Import secrets from .env files in your repo's vendor directories.
- **Code workspace draft composer.** Improved draft handling in the Code tab composer for multi-turn interactions.
- **Workbench pane resize handle.** Drag to resize the sidebar and main pane independently.
- **Transcript message gutter.** Timestamps and metadata shown in a gutter alongside transcript messages.
- Ships build 233 for Mac (signed Sparkle feed) with iOS/watchOS to TestFlight on the same build.
