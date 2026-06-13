# Continuum 0.38.0

A redesigned iPhone app, a reorderable Code sidebar, and a wave of provider-settings and analytics fixes.

- **Redesigned iPhone app.** A flat tab shell with Home, Usage, Code, and Chat — a cleaner, faster way to move around on iOS. (#430)
- **Reorder your projects.** Drag to set a stable, custom order for managed projects in the Code sidebar, and it sticks across launches. (#443)
- **Preferred account, at a glance.** Provider settings gain a "Preferred Account" column and a "Terminal Command" column so multi-account setups read clearly. (#437)
- **Friendlier nav tabs.** Nav tabs now show a pointing-hand cursor on hover and a tooltip with their keyboard shortcut. (#439)

## Fixes

- **Instant model dropdown.** The model picker is usable the moment you connect a provider, instead of lagging behind. (#433)
- **Cleaner provider settings.** OpenCode, OpenRouter, and authenticated providers are split into their own sections. (#438)
- **One OpenCode usage strip.** OpenCode now shows as a single two-zone usage strip instead of a duplicate empty column. (#440)
- **Accurate Claude weekly %.** The Claude weekly gauge reads correctly again, and secondary-account gauges come back to life. (#435)
- **Code repos stay put.** A Code repo no longer disappears from the sidebar after you archive its last session. (#434)
- **Sessions revive instead of erroring.** A Claude session whose terminal was retired now revives seamlessly rather than throwing an error. (#442)
- **One less confirmation.** Bypass mode skips the extra confirm when the repo is already trusted. (#441)
- **Tidier sidebar rows.** Dropped the redundant provider sub-label from Code sidebar branch rows. (#432)
- **iOS handoff fix.** Fixed a handoff-menu callback scope issue and a provider-choice exhaustiveness bug.

## Under the hood

- **Fable 5 removed from the Claude model selector** to comply with US export restrictions; past Fable usage still prices correctly in analytics. (#436)
- Removed the "N active sessions" Live Activity / Dynamic Island pill. (#431)

Ships build 241 for Mac (signed Sparkle feed), with iOS/watchOS to TestFlight and the App Store.
