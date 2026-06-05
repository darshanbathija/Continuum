# Design System — Continuum

**Direction: "Quiet Black Workbench."**

This is the design source of truth for all Continuum UI work (macOS, iPhone,
watchOS, and the Linux port). It replaces the previous Tahoe liquid-glass
system, which is preserved at
`docs/designs/DESIGN-tahoe-glass-archived-2026-05-27.md` for reference.

Created 2026-06-06 via `/design-consultation` (start-fresh). Direction set by
the user against three references (Cursor's dark editor, the Conductor.build
app, Google Antigravity 2.0) and pressure-tested by two independent design
voices (Codex + a Claude sub-agent), which converged on the system below.

## North Star

> "I open it and instantly see what my agents are burning. Calm, black, exact."

Every visual decision serves this one impression. The page stays dim; the only
thing that reads bright is the data. If a screenshot looks boring with no data
loaded, that is correct. The instant real numbers arrive, the instrument lights
up.

## Product Context

- **What this is:** A native control surface for coding agents. Live
  rate-limit / quota gauges for Claude Code, Codex, Antigravity, and Cursor,
  plus pay-as-you-go OpenCode spend, historical `$/token` analytics, a
  multi-provider Chat (broadcast one prompt to 2-3 models
  side by side), and a Sessions/Code workbench (repo + session navigation, chat
  thread, plan review, git diff, PR status, terminal output), plus device
  pairing.
- **Who it is for:** Developers running coding agents across many local
  projects, providers, branches, and devices.
- **Product type:** Native agentic-coding instrument with usage analytics and
  mobile + watch companion surfaces.
- **Heritage:** The original was a physical ESP32 gauge — a
  terra-cotta needle on black. The instrument metaphor survives; the
  terra-cotta is demoted to a single signal (the Claude provider color).

## Aesthetic Direction

- **Direction:** Quiet Black Workbench — an instrument-grade dark developer
  tool. Peers: Cursor's dark editor, Conductor, Antigravity 2.0.
- **Mood:** Calm, precise, engineered, native. A rack-mounted instrument, not a
  SaaS dashboard.
- **Decoration level:** Minimal. Structure comes from elevation steps and 0.5px
  hairlines, never from glass, blur, glow, gradients-as-decoration, or
  drop-shadow cards.
- **Theme:** Dark-first. v1 ships dark only; a light variant is a deliberate
  later follow-up, not a v1 requirement.
- **Color posture:** The UI is greyscale. Saturation is rationed and only ever
  appears as (a) a provider meter fill, (b) a provider dot / 3px row edge / chart
  segment, or (c) a semantic state signal. Nothing else is colored.
- **Platform feel:** Apple-native proportions, SF fonts, traffic-light chrome on
  Mac, iOS controls (segmented, switches, tab bars, large titles) on iPhone.

## Experience Principles

1. **Data is the only thing that glows.** Chrome is dim; live numbers, the
   active meter fill, and the current value are the brightest elements. Contrast
   comes from the figure/ground gap between dim chrome and bright data, not from
   coloring the chrome.
2. **Color means something.** Greyscale by default. When color appears, it
   carries provider identity or state — never decoration.
3. **The meter is the signature.** Quota reads as a horizontal rail meter
   (length = burn). It is the recurring instrument motif across every surface.
4. **Proportional for the human, monospace for the machine.** SF Pro speaks to
   the user; SF Mono carries every machine string (numbers, paths, commands).
5. **Hairline-as-structure.** Panels are separated by 0.5px seams and a one-step
   elevation lift, not by shadowed cards.
6. **One system across devices.** Mac, iPhone, and Watch reuse the same tokens,
   meter, provider semantics, and type rules.
7. **Motion is mechanical.** Values change like hardware (settle, roll, pulse),
   never with ambient idle animation.

## Typography

Apple system fonts only. Zero licensing, fully native, the correct choice for a
SwiftUI app on Mac/iOS/watch. `system-ui` is never used as a design abdication —
the roles below are explicit and deliberate.

- **Display / big metrics:** `SF Pro Rounded` (`-apple-system, "SF Pro Rounded",
  "SF Pro Display", system-ui`). Semibold/Bold. The big quota `%`, spend totals,
  and screen titles. Rounded terminals echo the meter and warm the panel without
  any color.
- **UI body / labels / nav:** `SF Pro Text` (`-apple-system, "SF Pro Text",
  system-ui`). Regular/Medium, 12-15px. The human voice; it should disappear.
- **Data numerals & machine strings:** `SF Mono` (`ui-monospace, "SF Mono",
  "Menlo"`). Medium for metrics, Regular for logs. Every `%`, `$`, token count,
  timer, delta, model id, branch, and file path.
- **Code / terminal / diffs:** `SF Mono`, 12-13px, line-height 1.4.
- **Etched labels:** `SF Mono`, uppercase, ~10.5px, letter-spacing 0.09em,
  color `fg-3` — section headers stenciled onto the instrument bezel.

### Type Scale

| Use | Size | Weight | Font | Notes |
| --- | ---: | ---: | --- | --- |
| Etched micro label | 10–10.5px | 600 | SF Mono | Uppercase, +0.09em tracking |
| Data / row metrics | 11–12px | 500–600 | SF Mono | Tabular, costs / timers / paths |
| Compact body | 12.5–13px | 500–600 | SF Pro Text | iPhone rows, dense cards |
| Body | 14px | 500 | SF Pro Text | Thread text, composer, copy |
| Pane / panel title | 15–16px | 600–700 | SF Pro Text | Provider name, group title |
| Big quota metric | 40–44px | 700 | SF Pro Rounded | Dashboard session `%`; the `%` glyph at ~0.5× size in `fg-3` |
| iPhone large title | 22–28px | 700–800 | SF Pro Rounded | Live / Analytics titles |
| Spend total | 40–42px | 700 | SF Pro Rounded | Analytics total |

### Typography Rules

- **Tabular numerals everywhere a number can change** (`font-variant-numeric:
  tabular-nums`) — costs, percentages, timers, token counts, deltas.
- **The machine/human handoff is the typographic signature.** The instant a
  glyph represents a measurement or a machine string, it switches to SF Mono.
  Prose, button labels, and headings stay proportional.
- Letter-spacing is `0` except etched uppercase labels (0.09em).

## Color

Dark-first. A slightly cool near-black so the app reads as a screen/instrument,
not paper. Elevation is value + hairline only — no shadows on inline panels.

### Neutral System (dark)

| Token | Value | Usage |
| --- | --- | --- |
| `bg` | `#050507` | App interior base / page |
| `surface-1` | `#0D0E11` | Primary panels, sidebars, cards |
| `surface-2` | `#131418` | Raised: composer, active row, controls |
| `surface-3` | `#1A1B1F` | Popover, menu, active control |
| `modal` | `#202126` | Highest: modal / detached window |
| `hairline-2` | `rgba(255,255,255,0.05)` | Faint internal rules |
| `hairline` | `rgba(255,255,255,0.085)` | Structural seams (0.5px) |
| `focus` | `rgba(255,255,255,0.20)` | Keyboard focus ring (1px) |
| `fg` | `rgba(255,255,255,0.94)` | Primary text, live numbers, meter highlight |
| `fg-2` | `rgba(255,255,255,0.62)` | Secondary text, axis labels |
| `fg-3` | `rgba(255,255,255,0.40)` | Etched labels, tertiary |
| `fg-4` | `rgba(255,255,255,0.26)` | Disabled / quiet metadata |
| `hover` | `rgba(255,255,255,0.04)` | Row / control hover (barely-there) |
| `pressed` | `rgba(255,255,255,0.065)` | Pressed state |
| `selection` | `rgba(255,255,255,0.075)` | Active selection fill |

Elevation must be a *perceptible* jump per step. Test on a real panel at arm's
length: if the seam between `bg` → `surface-1` → `surface-2` is invisible, the
step is too small. Hairlines must actually show — `0.085` is the floor; on the
darkest seams bump to `0.10`.

### Semantic State

Thin signals only (dot, hairline, text, or short meter cap). Never panel fills.

| Token | Value | Usage |
| --- | --- | --- |
| `live` | `#3CC07A` | Running / live-now dot (the only pulsing element) |
| `warn` | `#D6A23B` | Approaching cap (≥80%) |
| `error` | `#E5534B` | Over cap / failed / stop |
| `paused` | `#8A8A8A` | Paused / idle (neutral grey) |

### Provider Identity

Rationed to a whisper: a 6px dot, a 3px row/column edge, a chart segment, or the
meter fill. Never a provider-colored button, header, or background fill.

| Provider | Color | Notes |
| --- | --- | --- |
| Claude | `#D97757` | Terra-cotta. The heritage warmth survives as *only* this. |
| Codex | `#8A9099` | Graphite. Codex stays near-monochrome by nature. |
| Antigravity | `#5C9DFF` | Cool blue. |
| OpenCode | `#9B87D4` | Muted violet. Distinct from Antigravity while staying quiet. |
| Cursor | `#7FA8B5` | Cool steel. Mono identity, lighter/cooler than Codex graphite. |

### Meter Fills (the canonical rail coloring — treatment "T2")

The rail meter fill uses a muted provider glow→base gradient with a 1px lit top
edge, so it reads like a lit physical meter while staying restrained.

| Fill | Value |
| --- | --- |
| Claude | `linear-gradient(90deg, #E68A66, #C9603F)` |
| Codex | `linear-gradient(90deg, #9AA3AD, #6E7681)` |
| Antigravity | `linear-gradient(90deg, #79ADFF, #4A86E8)` |
| OpenCode | `linear-gradient(90deg, #B2A4E2, #7C6CB6)` |
| Cursor | `linear-gradient(90deg, #9BBFC9, #5E8893)` |
| Warn (≥80% cap) | `linear-gradient(90deg, #E2B45C, #C98A2E)` |
| Error (over) | `linear-gradient(90deg, #EC6A62, #D2433B)` |
| Track | `#202126` with `inset 0 0 0 0.5px rgba(255,255,255,0.05)` |
| Lit edge | `inset 0 1px 0 rgba(255,255,255,0.18)` on the fill |

Secondary meters (e.g. the weekly bar beneath the session bar) use the same
provider fill at `opacity: 0.5` so the hierarchy reads session-first.

## Spacing

- **Base unit:** 4px, shown. Dense data tables should feel engineered, not
  loosely arranged.
- **Scale:** 4 / 8 / 12 / 16 / 24 / 32 / 48.
- **Density:** Dense on Mac, comfortably dense on iPhone.

## Radius

Tight radii read as engineered; large radii read as consumer/bubbly. This is a
hard break from the old 18–28px glass radii.

| Token | Value | Usage |
| --- | ---: | --- |
| Row | 4px | Sidebar / list rows |
| Button | 5px | Buttons, small controls |
| Card / panel | 6px | Default panels and cards |
| Modal | 8px | Modals, popovers, the Mac window |
| Rail | 3px | Meter track + fill |
| Pill | 999px | Native segmented controls + switches only |

## Layout

### Structure

Hairline-as-structure: panels butt together and the 0.5px seam is the divider.
Shadows are reserved for genuinely floating surfaces (popovers, modals, the Mac
window), never inline cards.

### Mac Window

- Mac window radius 8px; shadow `0 30px 80px rgba(0,0,0,.55), 0 0 0 .5px
  rgba(0,0,0,.6)`.
- Titlebar 44px, `surface-1`, bottom hairline. Traffic lights `#E5534B` /
  `#D6A23B` / `#3CC07A` (12px). Tabs: Chat, Usage, Code, Settings. Active tab =
  22px high, 5px radius, `white@10%` fill, weight 700.
- Content padding 14px, gap 12px.

### Mac Usage Dashboard (signature surface)

- Top row: live provider panels (Claude, Codex, Antigravity, Cursor), each
  `surface-1` + hairline + 6px radius. OpenCode appears as a full-width
  pay-as-you-go spend strip when usage data is available because it has no
  rolling quota window.
- Each panel: header (provider dot + name + mono model + Menu-bar switch), a big
  SF Pro Rounded session `%` with an etched `SESSION` label + mono reset timer,
  the session **rail meter**, a dimmed weekly rail beneath it, and a sub-line
  (`auto-revive` state · `$X today`).
- Analytics panel below: header (etched `SPEND OVER TIME` + legend + range
  segmented `24h / 7d / 30d / 90d / All`), a `1.45fr 1fr` grid: stacked spend
  chart on the left, spend-by-repo list on the right.

### Mac Chat (broadcast)

- 248px sidebar + chat body. Mode toggle: Broadcast / Solo.
- Broadcast compares providers in **columns with hard vertical hairline
  dividers**, synchronized prompt headers, and a mono cost/latency footer per
  column. Provider identity shows as a 3px top edge or header dot on each column,
  not a colored panel.

### Mac Code Workbench

- `260px 1fr 380px` (review open) / `260px 1fr` (closed).
- Left: repo → session navigation, live counts, recent JSONLs. Center: thread +
  composer. Right: review tabs (Plan / Diff / Sources / PR / Term).

### Menu-bar Popover

- Compact operational surface (~`360 × 420`). Provider rail meters at 6px,
  session + weekly + reset timer, dense mono numerics. Not a miniature
  dashboard.

### iPhone

- iOS large titles, glass-free `surface-1` cards, native segmented controls and
  switches, floating tab bar (Chat, Live, Analytics, Code).
- Live tab: provider segmented control, hero session rail + `%`, weekly rail,
  auto-revive switch, synced-from-Mac footer.
- Hit targets ≥38px.

### watchOS

- Single rail meter + `%` + reset timer per provider; complication shows the
  rail (or a compact `%`). The rail survives down to complication size; drop the
  weekly bar and labels, keep fill + `%`.

## Components

### Rail Meter (the signature component)

- Track: 7px (Mac) / 7px (iPhone) / thinner on watch; `#202126`, 3px radius,
  inset hairline.
- Fill: provider gradient (treatment T2) from 0 to current %, 3px radius, with a
  1px lit top edge. Length is the signal; hue never carries the reading.
- Limit tick: 1px vertical at the warn threshold (80%), `rgba(255,255,255,0.40)`.
- Warn/error: fill stays provider color up to the tick; the portion past the
  threshold uses the warn (then error) gradient as a short cap, and the big `%`
  number adopts `warn`/`error`. The arc/fill before the tick never recolors.
- Weekly / secondary meter: same provider fill at `opacity 0.5`.
- The current `%` is the loudest element on the card (SF Pro Rounded, `fg`).

### Buttons

The brand accent is neutral, so the primary action is a light button, not a
chromatic one.

- **Primary:** background `rgba(255,255,255,0.92)`, text near-black (`#0A0A0C`),
  5px radius. Used for the single most important action (Send, Approve & run,
  Pair).
- **Secondary / ghost:** transparent, 0.5px hairline border, `fg-2` text; hover
  adds `hover` fill. Active tints border to `focus`.
- **Icon button:** square/circular; iPhone 38px, Mac 30–38px, sidebar inline
  24px.

### Switches

- iOS geometry: track 30×18 (or 34×22), thumb travel as standard, thumb `#fff`.
- Enabled fill: `live` (`#3CC07A`). Motion 150ms cubic-bezier `(0.3,0.7,0.4,1)`.

### Segmented Controls

- Pill track (`surface-1` + hairline), active segment `white@10%` fill + 0.5px
  inner shadow, mono labels. Used for range, mode, and provider selection.

### Composer

- Raised `surface-2` surface, 8px radius, not a plain text field.
- Chips (model, plan, autopilot, `@`, mic) at 24px high, 6px radius, hairline
  border.
- Send button: light circle (matches Primary). While a session runs it becomes a
  **LiveTicker**: a pill with a `live` dot, mono `$x.xxx · live`, and a secondary
  `<tok/s> · <elapsed>` line. Stop button inside.
- Placeholder copy (reuse verbatim): idle `Ask anything. Use / for skills, @ for
  files.`; running `Editing <file> — send a follow-up…`; plan `Refine the plan
  above…`.

### Provider Glyphs

Recognizable, distinct, not copied from provider marks. Rendered monochrome
(`fg` / `fg-2`) with the provider dot carrying the color.

- Claude: single asterisk-burst.
- Codex: abstract hexagonal interlock.
- Antigravity: twin sparkle.
- OpenCode: monochrome alpha-shaped silhouette.
- Cursor: monochrome cursor/agent silhouette; color only in dot/edge/meter.

### Charts

- Stacked bars, never area charts. Per-provider segments use the **same provider
  gradients as the meters** (color is consistent across meters, charts, and
  dots).
- **Vertical stacks** (spend over time): order top-to-bottom Cursor → OpenCode
  → Antigravity → Codex → Claude; rendered bottom-up so Claude is the
  foundation.
- **Horizontal stacks** (by repo): order left-to-right Claude → Codex →
  Antigravity → OpenCode → Cursor.
- Dashed/hairline grid lines, mono axis + dollar values, range selector
  required. When a provider is `$0` in the window, render a zero-height slice —
  keep it in the legend, never drop it.

## Motion

The motion language is mechanical instrument physics. This is the one place the
"meter" heritage is expressed in behavior.

- **Meter / value settle:** when a quota or counter updates, the fill settles
  with a short spring (~140ms, one subtle settle), like a galvanometer needle.
- **Odometer roll:** cost and token counters digit-roll on update (mono),
  signalling live measurement. No crossfade.
- **Live heartbeat:** the `live` dot is the only element that pulses (1Hz,
  opacity 0.5→1).
- **Standard transitions:** 120–160ms ease for hover, selection, tab, and
  control changes.
- **No ambient idle animation.** Nothing loops on an idle dashboard except the
  single live heartbeat.
- **Reduced motion:** honor `prefers-reduced-motion` / `accessibilityReduceMotion`
  everywhere — collapse loops to a single state change and shorten transitions to
  ≤30ms.

## Content & Labels

Concise, operational labels. Reuse: Chat · Usage · Code · Settings · Broadcast ·
Solo · Sync with iPhone · Menu bar · Auto-revive · Keep 5h timer ticking ·
Weekly · all models · Spend over time · Spend by repo · Plan ready · Sources ·
Term · Pair to Mac · Scan QR · Paste URL. Avoid vague labels (Explore, Get
started, Learn more, Dashboard) where a precise role exists.

## Accessibility & Usability

- **Never rely on color alone.** Provider color always travels with a glyph, a
  label, and the number. State always travels with text or position, not just
  hue. This matters more here precisely because color is rare.
- Keep `fg-2`+ for body text and `fg` for key data over near-black. Don't drop
  body text below `fg-3`.
- Hit targets ≥38px iPhone, ≥30px Mac.
- Tabular numerals for all changing numbers.
- Every icon-only control has an accessibility label / tooltip.
- Truncate long session / repo / file names predictably with ellipsis.
- Do not hide state behind hover on iPhone.

## Anti-Slop Guardrails

Never introduce: glass, blur, glow halos, purple/violet gradients, 3-column
icon-in-circle feature grids, centered marketing heroes, uniform bubbly
border-radius, gradient CTA buttons, or `system-ui` as the primary font.

**The single biggest risk for THIS direction is "black-on-black mush"** — a flat
grey screen where every panel sits at near-identical luminance, hairlines are
too faint to register, and the whole thing reads as one undifferentiated dark
blob. Avoid it by:

- Enforcing perceptible elevation deltas numerically (`bg` → `surface-1` →
  `surface-2` must each be a visible step).
- Keeping hairlines actually visible (`≥0.085`, `0.10` on the darkest seams).
- Letting the data be the brightness — `fg` at 0.94 belongs to live numbers, the
  meter, and the active value; chrome stays dim.
- One color event per view, maximum. If more than a single provider/state signal
  competes for the eye in a pane, pull it back to a dot.

## Implementation Notes

- Map every token here into the shared SwiftUI `Theme` layer; do not scatter
  hex/blur values per view. Shared primitives must exist for: panel, **rail
  meter**, primary/ghost button, switch, segmented control, composer chip, chart
  bar, and provider glyph.
- Dark-only for v1. A light variant is a later, deliberate addition.
- The standalone prototype uses `gemini` as the internal key for Antigravity;
  product code may keep the key, but user-facing labels say Antigravity.
- Replace all demo data (`clawdmeter`, `defx-frontend`, `ccwatch`,
  `internal-tools`, sample `$`/`%`) with real session/provider/repo state.
- Pairing must use a real payload with an honest fallback URL.

## Decisions Log

| Date | Decision | Rationale |
| --- | --- | --- |
| 2026-06-06 | Start fresh: replace the Tahoe liquid-glass system | User chose a new direction; old system archived at `docs/designs/DESIGN-tahoe-glass-archived-2026-05-27.md`. |
| 2026-06-06 | Adopt "Quiet Black Workbench" — fully-neutral near-black, dark-first | User references (Cursor dark editor, Conductor, Antigravity 2.0) + two converging design voices; the opposite of the previous glass look. |
| 2026-06-06 | Apple system fonts (SF Pro Rounded / Text / Mono) with a strict machine/human split | Native SwiftUI app; mono carries every machine string; rounded warms the meter without color. |
| 2026-06-06 | Ration color to meters, dots, chart segments, and state | Keeps the UI greyscale so the rare color lands; terra-cotta survives only as the Claude dot. |
| 2026-06-06 | Gauge = horizontal rail meter (not a ring dial) | Densest form; scales to menu bar, rows, and watch; lowest build cost; reuses the existing bar-meter path. |
| 2026-06-06 | Rail coloring = treatment T2 (muted provider glow→base gradient + lit edge) | User picked it from a 4-up comparison; reads as a lit instrument while staying restrained. Resolves the flat-grey "mush" risk. |
| 2026-06-06 | Motion = mechanical instrument physics (settle, odometer roll, 1Hz heartbeat) | Honors the meter heritage in behavior; no agentic IDE moves like hardware. Reduced-motion respected. |
| 2026-06-06 | Tight radius scale (4/5/6/8) | Engineered, not consumer; a hard break from the old 18–28px glass radii. |
