# Continuum 0.32.1

First update since 0.31.17 — it rolls up everything merged since then.

- **Custom OpenAI/Anthropic-compatible providers.** Point Continuum at any OpenAI- or Anthropic-compatible endpoint (base URL + API key + model id) in Settings → Providers. It probes the endpoint before saving, then offers the provider everywhere you pick a model — Mac Chat, Mac Code, and the iOS chat + new-session sheets — routing through both the Claude and Codex spawn paths.
- **Multiple Claude and Codex subscriptions side-by-side.** Add a second Claude or Codex account in Settings → Providers, pin chats and sessions to a specific account, watch both accounts' gauges, and have every account's history roll into the aggregate analytics. Per-account spawns stay config-isolated, and wrong-account billing fails closed instead of silently falling back to your primary subscription.
- **Analytics no longer pegs your CPU on a cold reparse.** The first full history parse used to peg three CPU cores for hours; it now uses a lock-free ISO-8601 parser with cache checkpointing.
- Ships build 228 for Mac (signed Sparkle feed) with iOS/watchOS to TestFlight on the same build.
