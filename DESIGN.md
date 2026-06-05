# Design System - Continuum

Generated from `.context/attachments/NMOKVp/Clawdmeter Redesign _standalone_.html`.

This is the design source of truth for Continuum UI work. The source HTML is a bundled React design canvas for the iOS 26 / Tahoe redesign. It contains Mac, iPhone, and menu-bar artboards plus a shared theme system, liquid-glass primitives, provider identity tokens, chat surfaces, a code workbench, usage analytics, settings, and pairing flows.

## Product Context

- **What this is:** A native desktop and mobile control surface for coding agents. Continuum combines quota/spend monitoring, multi-provider chat, local session control, worktree/session navigation, plan review, diffs, terminal output, provider setup, and device pairing.
- **Who it is for:** Developers who run coding agents across several local projects, providers, branches, and devices.
- **Product type:** Native agentic-coding workbench with usage analytics and mobile companion surfaces.
- **Design intent:** A serious workbench, not a marketing app. The UI should feel like a native Apple system surface fused with a coding IDE: quiet, precise, glassy, stateful, and fast to scan.
- **Primary source artifact:** Standalone React canvas with Mac, iPhone, and menu-bar artboards.

## Source Artboards

| Surface | Artboard | Size |
| --- | --- | --- |
| Mac | Chat - broadcast to 3 models | 1320 x 880 |
| Mac | Code IDE - plan review | 1320 x 880 |
| Mac | Usage dashboard | 1320 x 880 |
| Mac | Settings | 1320 x 880 |
| Mac | Menu bar popover | 420 x 420 |
| iPhone | Chat - broadcast | 420 x 910 |
| iPhone | Live - Claude | 420 x 910 |
| iPhone | Live - Codex | 420 x 910 |
| iPhone | Live - Antigravity | 420 x 910 |
| iPhone | Code | 420 x 910 |
| iPhone | Code - plan review | 420 x 910 |
| iPhone | Analytics | 420 x 910 |
| iPhone | Pairing | 420 x 910 |

The iPhone frame inside each mobile artboard is `402 x 874`.

## Aesthetic Direction

- **Direction:** Tahoe liquid-glass coding workbench.
- **Mood:** Calm, premium, native, operational. The interface can show many running agents, but the user should still understand attention, cost, quota, and next actions at a glance.
- **Decoration level:** Intentional and restrained. Glass, halos, provider glows, and wallpaper separate layers and convey state. Avoid decorative blobs, gratuitous gradients, oversized empty hero sections, and card-heavy marketing layouts.
- **Visual density:** Medium-dense on Mac, comfortably dense on iPhone.
- **Platform feel:** Use Apple-native proportions, SF fonts, traffic-light chrome on Mac, iOS segmented controls, iOS switches, tab bars, and large titles.

## Experience Principles

1. **Chat is the front door.** The first Mac artboard is Chat, and Chat appears as the first iPhone tab. Chat supports broadcast comparison and solo mode.
2. **Code is a real workbench.** The Code surface has repo/session navigation, live agent rows, thread context, plan review, diff, sources, PR state, and terminal output.
3. **Usage is always close.** Quota and spend surfaces are specific: session percentage, weekly percentage, reset timers, model names, auto-revive state, menu-bar inclusion, spend by provider, spend over time, and spend by repo.
4. **Provider identity carries meaning.** Claude, Codex, and Antigravity have distinct marks, colors, glows, model labels, costs, and comparison outcomes.
5. **Glass is structure.** Glass panels reveal hierarchy and depth. They should not obscure content.
6. **Mac and iPhone are one system.** The iPhone mirrors Mac state: provider focus, live quota, code sessions, plan review, analytics, and pairing.
7. **Controls must be real controls.** Use icon buttons for actions, segmented controls for mode/range/provider selection, switches for binary settings, swatches for color/theme/wallpaper, and clear CTAs for pairing and sending.

## Typography

- **Primary UI font:** `-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro", "Helvetica Neue", sans-serif`
- **Rounded display/numeric font:** `-apple-system, "SF Pro Rounded", "SF Pro Text", system-ui, sans-serif`
- **Monospace/data font:** `ui-monospace, "SF Mono", "Menlo", monospace`
- **Loading strategy:** Use system fonts. Do not add web fonts unless a future direction explicitly requires it.

### Type Scale

| Use | Size | Weight | Notes |
| --- | ---: | ---: | --- |
| Micro labels | 10 to 10.5px | 600 to 700 | Uppercase metadata, ticks, reset labels |
| Small labels | 11 to 11.5px | 600 to 700 | Section headers, provider metadata, chart labels |
| Titlebar controls | 12px | 600 to 700 | Mac tabs and status text |
| Compact body | 12.5 to 13px | 500 to 700 | iPhone rows, small cards |
| Body | 14px | 500 to 700 | Composer placeholder, iPhone copy, thread text |
| Pane titles | 15 to 16px | 700 | Provider names and group titles |
| iPhone large title | 22px | 800 | Mobile Live title |
| Card metric | 22 to 26px | 700 to 800 | Dense quota and weekly percentage |
| iPhone spend total | 42px | 800 | Analytics total |
| Desktop quota metric | proportional | 700 | `size * 0.36`; at 260px this is 93.6px |

### Typography Rules

- Use tabular numerals for costs, percentages, reset timers, token counts, and elapsed times.
- Use monospace for file paths, command output, token/cost micro-metrics, and pairing URLs.
- Keep letter spacing at `0` except for small uppercase labels, where `0.4px` to `0.5px` is allowed.
- Use rounded font for big metrics so percentages and spend totals feel native.

## Color

### Neutral System

| Token | Dark | Light | Usage |
| --- | --- | --- | --- |
| Page background | `#000000` | `#f4f6fa` | App interior base |
| Surface solid | `#0d0e11` | `#ffffff` | Solid panels and fallback cards |
| Surface solid 2 | `#15171b` | `#f7f8fb` | Secondary surfaces |
| Foreground | `rgba(255,255,255,0.96)` | `rgba(15,17,22,0.95)` | Primary text |
| Foreground 2 | `rgba(255,255,255,0.72)` | `rgba(15,17,22,0.66)` | Secondary text |
| Foreground 3 | `rgba(255,255,255,0.48)` | `rgba(15,17,22,0.46)` | Muted labels |
| Foreground 4 | `rgba(255,255,255,0.28)` | `rgba(15,17,22,0.26)` | Disabled or quiet metadata |
| Inverse foreground | `#0a0a0c` | `#ffffff` | Text on strong fills |
| Hairline | `rgba(255,255,255,0.10)` | `rgba(15,17,22,0.10)` | Borders and separators |
| Hairline 2 | `rgba(255,255,255,0.06)` | `rgba(15,17,22,0.06)` | Subtle fills and rails |

### Brand Legacy Anchor

- **Legacy Continuum accent:** `#d97757`
- **Canvas dark shell:** `#050608`
- **Canvas warm background:** `#f0eee9`
- **Logo/light stroke:** `#f0eee9`

The redesign expands beyond the original terra-cotta-on-black gauge language, but `#d97757` remains the historical Continuum warmth and should be used where a heritage accent is needed.

### Accent Themes

| Accent | Base | Deep | Glow | Use |
| --- | --- | --- | --- | --- |
| Halo | `oklch(0.78 0.16 220)` | `oklch(0.55 0.20 250)` | `oklch(0.88 0.13 205)` | Default primary accent |
| Ember | `oklch(0.72 0.16 40)` | `oklch(0.55 0.18 30)` | `oklch(0.82 0.14 50)` | Warm Continuum direction |
| Bloom | `oklch(0.74 0.18 320)` | `oklch(0.55 0.22 320)` | `oklch(0.84 0.15 320)` | Expressive magenta variant |
| Spring | `oklch(0.78 0.16 155)` | `oklch(0.58 0.18 155)` | `oklch(0.88 0.14 145)` | Green success-forward variant |

### Provider Colors

| Provider | Base | Deep | Glow | Halo | Notes |
| --- | --- | --- | --- | --- | --- |
| Claude | `oklch(0.72 0.13 45)` | `oklch(0.48 0.14 35)` | `oklch(0.83 0.10 50)` | `oklch(0.78 0.16 50)` | Warm orange, single asterisk-burst mark |
| Codex | `oklch(0.30 0.01 260)` | `oklch(0.12 0.01 260)` | `oklch(0.55 0.02 260)` | `oklch(0.70 0.16 235)` | Near-neutral charcoal, abstract hexagonal interlock |
| Antigravity | `oklch(0.62 0.20 255)` | `oklch(0.45 0.22 265)` | `oklch(0.78 0.18 250)` | `oklch(0.72 0.22 285)` | Blue/purple, twin sparkle mark |

### Semantic Colors

| Semantic | Color | Usage |
| --- | --- | --- |
| Success/live | `#28c840` | Live dots, successful checks, enabled switches |
| Warning/running | `#febc2e` | Running checks, warning state, Mac yellow traffic light |
| Error/stop | `#ff5f57` | Stop/error, Mac red traffic light |
| Strong white | `#ffffff` | Button text on accent fills, QR cells in dark mode |
| Strong black | `#000000` | QR cells in light mode and high-contrast dark surfaces |

### Session Status

Sessions render a 5-7px dot that maps state to the semantic palette. Running sessions add a 6px glow on the dot so they read at a glance from the sidebar.

| Status | Color | Notes |
| --- | --- | --- |
| running | `#28c840` (success) | 6px glow on the dot |
| planning | foreground 3 (muted) | no glow |
| paused | `#febc2e` (warn) | no glow |
| done | active accent | no glow |
| degraded | `#ff5f57` (danger) | no glow |

## Glass And Surfaces

### Glass Model

The prototype uses a global glass intensity slider:

- Input range: `0..100`
- Blur radius: `8px..44px` via `8 + intensity * 36`
- Saturation:
  - muted wallpapers: fixed at `100%`
  - colorful wallpapers: `110%..210%`
- Tint multiplier: `0.5..1.2`
- Dark glass tint: `rgba(255,255,255,0.06 * tintMul)`
- Light glass tint: `rgba(255,255,255,0.45 * tintMul)`
- Dark high tint: `rgba(255,255,255,0.10 * tintMul)`
- Light high tint: `rgba(255,255,255,0.55 * tintMul)`
- Glass ring:
  - dark: `rgba(255,255,255,0.18)`
  - light: `rgba(255,255,255,0.7)`
- Glass inner highlight:
  - dark: `rgba(255,255,255,0.10)`
  - light: `rgba(255,255,255,0.6)`
- Glass shadow:
  - dark: `0 12px 40px rgba(0,0,0,0.45), 0 1px 0 rgba(255,255,255,0.06) inset`
  - light: `0 12px 40px rgba(15,17,22,0.10), 0 1px 0 rgba(255,255,255,0.5) inset`
- Hairline thickness: `0.5px` — the opacity tokens above determine color; the line width is always 0.5px.

### Radius Scale

| Token | Value | Usage |
| --- | ---: | --- |
| Small radius | 10px | Icon buttons, small controls |
| Base radius | 18px | Default glass panels |
| Large radius | 26px | Large floating cards and device glass |
| Pill radius | 999px | Segmented controls, tabs, badges, toggles |
| Mac window radius | 14px | Top-level Mac artboard window |
| Panel radius | 20px to 22px | Main cards, sidebars, iPhone cards |
| QR panel radius | 28px | Pairing QR glass block |

### Wallpaper Options

| Wallpaper | Treatment | Use |
| --- | --- | --- |
| Aurora | Multi-point blue/cyan/magenta radial gradients | Colorful Halo mode |
| Dawn | Warm lower glow plus violet tint | Warm mood |
| Graphite | Neutral radial gray | Default standalone wallpaper |
| Code | Subtle 22px editor-line stripes | Workbench/editor emphasis |
| Studio | Flat neutral gradient | Minimal mode |

Avoid color orbs on Graphite, Studio, and Code. The prototype intentionally suppresses decorative orbs there.

## Layout

### Mac Window

- Mac artboards are `1320 x 880`.
- Top-level Mac windows use 14px radius and `0 30px 80px rgba(0,0,0,0.45), 0 0 0 0.5px rgba(0,0,0,0.5)`.
- Floating titlebar sits at `top: 10px`, `left/right: 10px`, height `44px`, gap `10px`.
- Traffic lights are 12px circles in `#ff5f57`, `#febc2e`, and `#28c840`.
- Main content begins at `top: 64px`, with 10px outer gutters.
- Titlebar tabs are Chat, Usage, Code, Settings. Active tabs use a filled/glass pill with 22px height and 7px radius.

### Mac Chat

- Layout: 248px glass sidebar plus flexible chat body.
- Body: column headers, scrollable stream, and bottom composer.
- Mode toggle in titlebar: Broadcast and Solo.
- Broadcast mode compares Claude, Codex, and Antigravity side by side.
- Conversation history is grouped into Pinned, Today, and Earlier.
- Reply cards include provider glyph, model, token count, cost, time, winner/star state, code blocks, and actions such as Re-run, Copy, and Continue from here.
- Composer includes attachments, microphone, autopilot/bolt affordance, per-send estimated cost, and primary send button.

### Mac Code IDE

- Grid: `260px 1fr 380px` when review pane is open; `260px 1fr` when it is closed.
- Left pane contains repo sections, live session counts, active sessions, recent branches/commits, search, filter, and new project/session actions.
- Center pane contains thread header, user message, tool reads/greps, assistant explanation, running state, and composer.
- Right pane has tabs: Plan, Diff, Sources, PR, Term.
- Plan state highlights a ready plan with accent glow and numbered steps.
- Diff state uses explicit add/delete colors and code context.
- Terminal state should show real command output in monospace with pass/fail status.

### Mac Usage Dashboard

- Top provider grid: three equal columns for Claude, Codex, and Antigravity.
- Provider card minimum height: 380px.
- Each provider card includes glyph, name, model, Menu bar toggle, session quota, weekly quota, reset timers, and auto-revive state.
- Quota visualization uses a large numeric percentage plus horizontal pill bar. The original function name is `QuotaOrb`, but the visual is a single pill bar.
- Analytics row:
  - Header with legend and range selector.
  - Range selector: 24h, 7d, 30d, 90d, All time.
  - Grid: `1.45fr 1fr`.
  - Left chart: stacked provider spend over time.
  - Right chart: spend by repo.
- Chart bars are stacked in provider order: Antigravity, Codex, Claude.

### Mac Settings

- Settings is organized into preference cards.
- Appearance contains Theme, Surface, Background vibrance, and Accent.
- Quota and sync contains Auto-revive 5h timer, Mirror to iPhone, and Notify at 90%.
- Use swatches for visual settings. Do not represent color or background choices as plain text-only buttons.
- Settings controls should update live preview/tokens when possible.

### Menu Bar Popover

- Artboard is `420 x 420`.
- Treat it as a compact operational surface, not a miniature dashboard.
- Prioritize current provider/session quota, weekly state, reset timer, and quick sync/status affordances.
- Use dense quota bars and tabular numeric percentages.

### iPhone

- Prototype device frame is `402 x 874` inside 420 x 910 artboards.
- Outer phone radius: 52px. Dynamic Island: 126 × 37 at top center.
- Use status bar, large titles, glass tab bar, and iOS bottom-safe-area spacing. Status bar sits inside top 56px of safe area; tab bar reserves 92px from bottom (38px when hidden).
- Tab bar: floating capsule at `bottom: 24, left/right: 16`, glass `radius 999, padding 6`. Tab buttons are `flex: 1, height: 44, radius 999, font-size 13` (active weight 700, idle 600), icon size 16, gap 6.
- Tab items: Chat, Live, Analytics, Code (the `sessions` key in the prototype labels as `Code`).
- Home indicator: 139 × 5 capsule, 34px reserved zone, padding-bottom 8.
- iPhone should feel like a companion control plane, not a read-only mirror.

### iPhone Chat

- Mirrors the Mac broadcast concept.
- Reply cards expose model, token count, cost, winner state, and code blocks.
- Winner/Pick controls let the user choose the best answer per turn.
- Composer has plus, microphone, and send affordance.

### iPhone Live

- Header: small `Continuum` label and large `Live` title.
- Provider segmented control: Claude, Codex, Antigravity.
- Hero quota: session percentage plus reset timer.
- Weekly card: percentage, reset timer, and provider-colored pill bar.
- Auto-revive card: refresh icon, text, and iOS-style switch.
- Footer: updated timestamp, synced-from-Mac text, and refresh/pairing action.

Live demo values from the prototype:

| Provider | Session | Weekly | Session reset | Weekly reset | Model |
| --- | ---: | ---: | --- | --- | --- |
| Claude | 67% | 42% | 2h 18m | 4d 6h | Sonnet 4.5 |
| Codex | 34% | 28% | 4h 02m | 6d 1h | gpt-5 |
| Antigravity | 89% | 61% | 58m | 5d 2h | antigravity-pro |

### iPhone Code And Plan Review

- Code uses repo cards and collapsible repo sections.
- Search field includes microphone icon.
- Repo rows show provider glyph, title, status dot, model, mode, and live count.
- New session action is a 38px icon button with plus icon.
- Plan review nav contains back button, session chip, provider glyph, title, status, model, mode, and settings/sliders icon.
- Thread includes user request, tool reads/greps, assistant summary, and a compact plan card.
- Plan card has accent halo, sparkles icon, `Plan ready`, step count, estimated cost, and numbered steps.
- Composer placeholder is `Refine the plan...`.

### iPhone Analytics

- Period segmented control: Today, 7d, 30d, All.
- Total card includes total spend, delta vs prior period, mini stacked chart, and provider spend chips.
- By repo list mirrors Mac analytics with stacked provider bars.
- Prototype total: `$39.32`, `+14% vs last week`.

### iPhone Pairing

- Title: Pair to Mac.
- Primary visual: 280 × 280 QR glass block.
  - Outer halo: `position: absolute, inset: -30, border-radius: 50, radial-gradient(60% 60% at 50% 50%, accentGlow @ 30%, transparent 70%), filter: blur(10px)`.
  - Glass: `raised` tone, `radius: 28, padding: 28`. Inner FakeQR renders at 224px.
  - Corner brackets: four 32×32 L-shapes at each outer corner (`top/bottom: -6, left/right: -6`). Stroke `3px solid accent`, shadow `0 0 10px accent@50%`. Asymmetric `border-radius` so each bracket bends inward (`10px 0 10px 0` on TL/BR, `0 10px 0 10px` on TR/BL).
- Title row beneath QR: 18px weight 800 letter-spacing -0.3 rounded font ("Point your camera at the QR"), then 14px fg3 sub-copy.
- Secondary action: paste pairing URL surfaced as a glass chip — `radius 14, padding 12 14`, link icon (15px) + mono URL preview + accent "Paste URL" label.
- Primary CTA: AccentButton size `l`, full width: "Scan QR" with QR icon.
- The prototype QR is fake. Product implementation must use real pairing payloads.
- The Mac surface should match: QR popover at 280×280 with the same halo + bracket spec; the Settings → Pairing pane uses the same dimensions (do not shrink to 160×160 or 200×200).

## Components

### Glass

All primary surfaces should route through a shared glass primitive:

- `panel`: main cards, sidebars, large surfaces.
- `raised`: important cards and composer surfaces.
- `chip`: titlebar controls, segmented controls, badges, compact rows.

Glass must support solid and translucent modes. Do not duplicate one-off translucent backgrounds across views.

### Pills And Buttons

- **Pill:** passive or low-emphasis label/button, 999px radius.
- **AccentButton:** primary action, gradient from accent base to accent deep, full pill (999px). Sizes:
  - small: 28px high, 12px label
  - medium: 32px high, 13px label
  - large: 38px high, 14px label
  - Horizontal padding is `height × 0.5` on every size.
  - Shadow: `0 0 0 0.5px accentDeep, 0 4px 12px accentDeep@30%, inset 0 1px 0 white@16%, inset 0 -1px 0 black@15%`.
- **GhostButton:** low-emphasis action on glass, 999px radius. Sizes:
  - small: 26px high, 12px label
  - medium: 30px high, 12.5px label
  - large: 36px high, 13px label
  - Active state tints the border `accent`, fills with `accent @ dark 0.15 / light 0.10`.
- **Icon button:** square or circular. iPhone uses 38px (`IOSRoundIconBtn`); Mac uses 30-38px. Sidebar inline icon buttons are 24px (e.g. RepoSection `+`, filter, folderPlus).
- **Mac active titlebar tab:** 22px high, 7px radius, 12px text (active weight 700, idle 600). Active background: `white@10%` (dark) / `#fff` (light) with `0 1px 2px black@10%, 0 0 0 0.5px black@8%` shadow.
- **Segmented controls:** pill track with active segment fill and shadow. iOS active state on the *provider* segmented control uses `accent@(dark 0.42 / light 0.28) × tintMul` — for Codex, set `tintMul = 2.6` because Codex's brand chroma is near-neutral and the default tint reads as transparent.

### Provider Glyphs

Provider glyphs must be recognizable, distinct, and not copied directly from provider marks:

- Claude: single asterisk-burst.
- Codex: abstract hexagonal interlock.
- Antigravity: twin sparkle.

Glyphs appear in chat headers, reply cards, provider segmented controls, session rows, analytics legends, and quota cards.

### Quota Meter

- Use a numeric percent plus horizontal pill bar.
- Session quota and weekly quota share visual grammar.
- Provider gradients always run from provider glow to provider base.
- Use tabular numerals.
- Dense contexts show a compact percent and 6px bar.

### Charts

- Stacked bars, not area charts.
- **Vertical stacks** (Mac "Spend over time", iOS "Mini spend chart"): provider order top-to-bottom is **Antigravity → Codex → Claude**. Bars render bottom-up so Claude is the foundation and Antigravity sits on top.
- **Horizontal stacks** (Mac + iOS "By repo"): provider order left-to-right is **Claude → Codex → Antigravity**. This is intentional and differs from the vertical stack — keep both in sync with this rule.
- Use dashed or hairline grid lines.
- Use monospace for y-axis and precise dollar values.
- Range selector is required for Mac analytics. Mac: `24h / 7d / 30d / 90d / All time`. iPhone: `Today / 7d / 30d / All`.
- Per-provider bar fill is always `linear-gradient(180deg, provider.glow, provider.base)` with a 50% provider-base box-shadow.
- When a provider has $0 cost across the active window (e.g. Antigravity from CLI logs), render a zero-height slice — do not exclude the provider from the stack — so the legend stays honest. A separate request-count panel is acceptable as an auxiliary surface but does not replace the cost stack.

### Toggles

- Use iOS switch geometry:
  - Track: 34 x 22
  - Padding: 2px
  - Thumb: 18 x 18
  - Thumb travel: 12px
- Enabled color: `#28c840`.
- Motion: 150ms with cubic-bezier `(0.3, 0.7, 0.4, 1)`.

### Composer

- Composer is a raised glass surface, not a plain text field.
- Mac composer: glass `radius: 18`, inner text padding `14px 16px 6px`, chip row padding `6px 10px 10px`.
- iPhone composer: glass `radius: 22`, padding `10px 8px 10px 14px`.
- Three states: **idle** (default chrome), **running** (text dims to 55%, accent rim pulses 1.8s, send replaced by LiveTicker), **plan** (text dims, send disabled, PlanHalo above owns approval).
- **ComposerChip:** 26px high, `radius 8`, `padding 0 9px` (or 26×26 icon-only). Hairline border, optional accent tint when active. Used for model, autopilot/plan, paperclip, code, mic.
- **Send button (Mac):** 34×34 circle, `linear-gradient(180deg, accent, accentDeep)`, white arrow icon, soft accent shadow. Disabled in plan mode (hair2 fill, fg4 icon, `cursor: not-allowed`).
- **Send button (iPhone):** 38×38 circle, same gradient and shadow as Mac.
- **LiveTicker** (replaces Send while a session is running): 34px high, `radius 999`, accent rim `inset 0 0 0 1px accent@40%`, fill `linear-gradient(90deg, accent@18%, accent@10%)`. Inner stop button: 26×26 circle (white in dark mode / `#15171b` in light) with black/white stop icon. Right side shows live `$x.xxx` mono + `● live` accent + secondary line `<tok/s> · <elapsed>`.
- It should support prompt text, file/command chips, attachments, microphone, autopilot/bolt affordance, send button, live running/cost state, and plan refinement state.
- Placeholder examples (use these copy strings, do not invent new ones):
  - idle: `Ask anything. Use / for skills, @ for files.`
  - running: `Editing <file> — send a follow-up…`
  - plan: `Refine the plan above… (e.g. "skip the migration step, just add the test")`

### Review Pane

Review pane tabs:

- Plan
- Diff
- Sources
- PR
- Term

Tab strip: each tab is `flex: 1`, 30px high, `radius 8`, `font-size 11.5` (active weight 700, idle 600). Active fill `white@10%` (dark) / `#fff` (light) with the same `0 1px 2px black@10%, 0 0 0 0.5px black@8%` shadow used on titlebar tabs. Icon + label, gap 5px.

The review pane should prefer concrete, executable state:

- Plan: numbered steps and estimated cost.
- Diff: file path, hunk context, additions, deletions.
- Sources: file/source list with reasons.
- PR: checks and PR status.
- Term: command output.

### Plan Halo / Plan Card

The single canonical surface for "plan ready · review before run." Used in the Mac thread (full-width) and on iOS (compact mini).

- **Aura behind card is static, not animated.** Mac: `inset: -28, radius: 38, radial-gradient(60% 60% at 50% 30%, accentGlow @(dark 0.30 / muted 0.10), transparent 70%), blur 8px`. iPhone: `inset: -20, radius: 30, blur 6px`. No `repeat-forever` pulse — the halo communicates state once, statically.
- Glass card: `raised` tone, `radius: 20`.
- Accent block (leading): Mac 28×28 / iOS 26×26, `radius 10` (Mac) / `9` (iOS), `linear-gradient(180deg, accent, accentDeep)`, sparkles icon in white, soft accentDeep@35% shadow + inset white@22% highlight.
- Header: uppercase `Plan ready · review before run` (Mac) or `Plan ready` (iOS) in fg3 11.5px, then a bold detail line `N steps · est. M tool calls · ~$X.XX` in fg 14px.
- Step list: ol with no list-style. Each step has a leading 22×22 (Mac) / 18×18 (iOS) `radius 6-7` badge containing the step number in mono 11px. Badge background `hair2`, label color `fg2` — except step 1 which uses `accent@18%` fill and `accent` text.
- Actions row: ghost "Refine" + ghost "Edit plan" on Mac (size m), ghost "Refine" (size l, flex 1) on iOS. Trailing accent "Approve & run" (size m on Mac, size l flex 2 on iOS) with keyboard hint `⇧⏎` rendered at 70% opacity weight 500.
- Mac action row also shows `Will commit to <branch>` in fg3 with a branch icon, sitting between the ghost buttons and the accent CTA.

## Motion

- Default interaction transitions: 120ms to 160ms.
- Segmented controls: background, box-shadow, and color transition over 160ms ease.
- Buttons/tabs: background, border-color, and color transition over 120ms.
- Switch thumb: 150ms cubic-bezier `(0.3, 0.7, 0.4, 1)`.
- Composer running rim: 1.8s `ease-in-out infinite` opacity pulse on the accent-rim `box-shadow` only, applied to the composer surface while a session is running. **The Plan Halo aura is static** — do not pulse it.
- Spinners: 0.9s linear (14×14 ring, 1.5px stroke, 25% accent track with full-accent top arc).
- Honor `prefers-reduced-motion` / `accessibilityReduceMotion` everywhere: collapse repeating animations to a single state change (no infinite loops) and shorten interaction transitions to ≤30ms.

Motion must clarify state changes. Avoid ambient animation on idle dashboards.

## Content And Labels

Use concise, operational labels. Avoid instructional filler in the UI.

Preferred labels from the prototype:

- Chat
- Usage
- Code
- Settings
- Broadcast
- Solo
- Sync with iPhone
- Menu bar
- Keep 5h timer ticking
- Auto-revive
- Weekly - all models
- Spend over time
- Spend by repo
- Plan ready
- Sources
- Term
- Pair to Mac
- Scan QR
- Paste URL

Avoid vague labels like `Explore`, `Get started`, `Learn more`, or `Dashboard` when the surface has a more precise role.

## Accessibility And Usability

- Hit targets should be at least 38px on iPhone and at least 30px on Mac unless constrained by native titlebar chrome.
- Do not rely on color alone for provider/state distinction. Pair provider color with glyph, label, model, and numeric data.
- Preserve contrast over translucent surfaces. If wallpaper reduces readability, increase glass tint or use solid mode.
- Keep chart and quota values readable with tabular numerals.
- Every icon-only control needs an accessibility label or tooltip.
- Long session names, repo names, and file paths must truncate predictably with ellipsis.
- Do not hide important state behind hover on iPhone.

## Implementation Notes

- Map these tokens into the shared SwiftUI theme layer where possible instead of scattering colors and blur values per view.
- Shared primitives should exist for glass panels, pills, provider glyphs, project glyphs, icon buttons, segmented controls, quota meters, chart bars, switches, composer chips, and review tabs.
- The standalone prototype uses `gemini` as the internal key for Antigravity. Product code may keep that key for compatibility, but user-facing labels should say Antigravity when the runtime is Antigravity.
- Demo data in the HTML includes `defx-frontend`, `ccwatch`, and `internal-tools`. Product implementation must replace demo values with real repo/session/provider state.
- The pairing QR in the prototype is visual only. Product implementation must generate a real pairing code and show an honest fallback URL.
- Code and Chat should remain distinct modes but share transcript/session data. Avoid creating isolated UI silos.
- Mac and iPhone should reuse provider colors, glyphs, quota meters, spend charts, and status semantics.
- Dark mode is the default prototype mode with Graphite wallpaper, translucent surface, Halo accent, and Claude provider focus.

## Decisions Log

| Date | Decision | Rationale |
| --- | --- | --- |
| 2026-05-27 | Created root `DESIGN.md` from standalone redesign HTML | The HTML contained the canonical React prototype, artboards, theme tokens, glass primitives, and platform surfaces. |
| 2026-05-27 | Adopt Tahoe liquid-glass workbench direction | The source artifact consistently uses glass panels, Apple system fonts, native controls, and agent-workbench layouts. |
| 2026-05-27 | Preserve provider-specific identity tokens | Claude, Codex, and Antigravity are visually and functionally distinct across chat, usage, sessions, and analytics. |
| 2026-05-27 | Keep Chat first and Code production-grade | The source artboards make Chat the hero and Code a real session/workbench surface with plan, diff, PR, source, and terminal states. |
| 2026-05-27 | Reconcile DESIGN.md against the canonical Tahoe HTML | Decoded the bundled JSX modules and absorbed gaps: session-status semantic table, AccentButton/GhostButton sizing scale, ComposerChip + Send button + LiveTicker geometry, static Plan Halo (no pulse) spec, vertical vs horizontal chart stack order, iPhone tab-bar geometry, QR popover halo + corner brackets, iOS Codex tint-boost rule (2.6× on segmented control), `prefers-reduced-motion` requirement, hairline 0.5px thickness. |
