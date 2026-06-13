# Continuum 0.37.0

Spawn a grid of agent terminals, run agents on remote and cloud hosts, dictate hands-free with voice, and find files instantly with built-in fuzzy search — plus a new provider picker and a lot of Code-tab polish.

- **Spawn mode — a grid of agents.** Launch a grid of agent terminals on the Code tab and watch several agents work side by side at once. (#413)
- **Run agents anywhere — multi-host execution.** Hand a session off to a remote or auto-provisioned cloud host, with tailnet-aware routing and per-host run-minute tracking, so heavy work doesn't tie up your Mac. (#417)
- **Hands-free voice dictation.** Hold the Fn key to dictate into the composer (or any app) with an on-screen overlay, on-device transcription via WhisperKit, and a new Voice settings tab. (#422)
- **Instant file search.** A built-in fuzzy file finder powers Code-tab file search and gives your agents a fast repo search tool out of the box. (#423)
- **Pick any provider.** A new OpenCode-style provider picker with logos, plus inline custom OpenAI/Anthropic-compatible providers and OpenCode partner models. (#408, #417)
- **Queue your next prompts.** Stack composer follow-ups above the input and steer a queued message mid-turn instead of waiting for the agent to finish. (#414)
- **Share skills as Markdown.** A Share button in Skills settings downloads any skill as a Markdown file. (#409)
- **Branch & PR status at a glance.** GitHub Octicon branch/PR icons now mark Code sidebar rows. (#418)
- **Cleaner right pane.** A simpler right-pane toggle with gutter hover states. (#411)

## Fixes

- **Menu-bar popover behaves.** Collapsing the menu-bar popover no longer pops open the dashboard. (#416)
- **Secondary accounts populate.** Secondary-account gauges now fill in on refresh. (#428)
- **Usage readability.** The 100% metric no longer wraps in narrow columns, and the redundant "vs prior" delta is gone from the chart header. (#419, #427)
- **Tidier Code workbench.** Tighter horizontal padding, draft tabs on one line, unified permission-mode chip styling, hover highlighting on the Skills tab, and cleaner managed-sidebar headers. (#425, #420, #421, #410, #424)

## Under the hood

- **Product analytics.** Anonymous, pairing-aware PostHog instrumentation across the Mac and iOS tabs to guide what we build next. (#412, #415)

Ships build 237 for Mac (signed Sparkle feed) with iOS/watchOS to TestFlight.
