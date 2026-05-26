# Plan Progress Bar — Independent Design Review, Pass 6

**Reviewer:** independent designer, no shared context with prior passes.
**Target:** Tahoe theme conformance for the plan-progress affordance shown in
the sidebar session row (Mac) and the iOS sessions popover.
**Artifacts reviewed:**

- `plan-progress-bar-mac-final.png` — three live states (3/8 partial, 6/6
  complete with halo-tinted check, 0/5 just-approved).
- `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift`, lines ~1360–1415.
- `apple/ClawdmeteriOS/Tahoe/IOSCodeView.swift`, lines ~549–587.
- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/TahoeQuotaBar.swift`
  (`TahoePillBar`, lines 84–129).
- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/TahoeTokens.swift`
  (provider `halo`, `glow`, `deep` definitions, lines 80–120).
- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/AgentKind+TahoeProvider.swift`.

I scored before re-reading the brief about what changed in pass 6, then
cross-checked.

---

## Dimension-by-dimension scoring

### Theme match — 24 / 25

What the bar does right against the Tahoe pattern fleet:

- `TahoePillBar` is the same primitive used by `TahoeQuotaBar` and
  `TahoeMenuBarMeter` (same file). Picking it instead of `ProgressView`
  means the plan progress visually rhymes with the quota and meter
  surfaces — same capsule, same `[halo → glow]` gradient, same 0.45s
  ease-in fill, same 5pt halo shadow. This is the cleanest possible
  citation of the existing design language.
- The 6pt bar height is the standard Tahoe pill height (matches the
  quota bar call-site on line 44 and the menu-bar meter on line 186 of
  `TahoeQuotaBar.swift`). No new dimension introduced.
- Pass 6's key move is honest: the milestone count and check now use
  `provider.halo.color`, which is exactly the leading anchor of the bar
  gradient (`colors: [provider.halo.color, provider.glow.color]` —
  `TahoeQuotaBar.swift:114`). That keeps the complete state inside the
  bar's two-color vocabulary instead of bringing in a third hue.
  Visually this reads as "the bar's accent is now telling the rest of
  the row what color it is" — that is exactly the Tahoe pattern.
- Looking at `TahoeTokens.swift` to confirm the regression fix is real:
  `codex.deep` is `OKLCH(l: 0.12, c: 0.01, h: 260)` (near-black, chroma
  0.01 → effectively grey), while `codex.halo` is
  `OKLCH(l: 0.70, c: 0.16, h: 235)` (legible cool blue). Same problem
  exists for `cursor.deep` (l 0.18). Switching to `halo` was the right
  call — it isn't just an aesthetic preference, it's the only choice
  that survives dark-mode + low-luminance providers.
- Provider-tinted via `session.agent.tahoeProvider` / `s.agent` →
  Claude rows get the warm orange of the screenshot, Codex rows get
  cool blue, etc. The screenshot shows the correct Claude tinting and
  the halo shadow ring around the fill on the 6/6 state.

The single quarter-point I'm withholding: the proof PNG only shows the
Claude provider. Theme cohesion across providers is asserted in code
(and I've verified the token definitions), but not visually
demonstrated. A four-up of Claude/Codex/Gemini/OpenCode at 6/6 would
close this. Not enough to drop a full point — the code path is shared
and the token values are sound — but I cannot fully verify what I
cannot see.

### Visual hierarchy — 20 / 20

- Row reads in the right order: status dot → title → status line →
  progress affordance → count. The count is on the right rail aligned
  to the rest of the meta column, so the eye sweeps left-to-right
  along the bar and lands on the milestone count without backtracking.
- At 6/6 the row gets exactly the right amount of additional emphasis:
  the bar fills, a small halo-tinted check appears between the bar and
  the count, and the count itself switches to `.bold` from
  `.semibold` and inherits the same halo tint. Three signals
  reinforcing one meaning, in one color. No competing accent.
- The Claude warm orange against the cream sidebar background (visible
  in the PNG) creates strong figure-ground without screaming. The
  partial 3/8 state at the top reads as "in progress" because it's
  the same orange but unmodulated by the check or bold weight.
- The just-approved 0/5 state correctly renders as bar track only with
  the count in `t.fg2` — no orange anywhere on the row, which
  preserves the "approved but daemon hasn't computed yet" pre-state.
  This is the right call: an orange-filled-zero would lie about state.

### State coverage — 15 / 15

Three states present in the proof, code confirms a fourth:

1. **0/total just-approved** — visible in PNG, count in neutral fg2,
   bar shows track only because `percent` evaluates to 0 (the bar
   correctly degenerates to width 0; see
   `TahoeQuotaBar.swift:116-117`).
2. **partial (3/8)** — visible in PNG, bar at ~37%, count in fg2,
   semibold.
3. **complete (6/6)** — visible in PNG, bar at 100%, check appears,
   count goes bold + halo tint.
4. **defensive over-complete (e.g. 7/6)** — handled in code via
   `safeCompleted = max(0, min(progress.completed, progress.total))`.
   This is the right defensive move. Bar renders at 100%, count
   renders as `6/6` (because `safeCompleted` is clamped to `total`).
   Both the visual fill and the displayed numerator use the same
   clamped value, so the bar can never lie about a value the row also
   shows.
5. **total = 0** edge — `max(1, Double(progress.total))` in the
   denominator prevents NaN. `isComplete` is gated on
   `progress.total > 0`, so a zero-total plan does not glow as
   "complete". Correct.
6. **session.planProgress = nil** — `if let progress = ...` falls
   through, no bar drawn. Correct (no bar means no plan, which is
   what we want before a plan is approved at all).

All six states are accounted for.

### Accessibility — 10 / 10

- `accessibilityElement(children: .combine)` rolls the HStack into one
  element. Without this, VoiceOver would walk the bar, the check, and
  the text separately.
- `accessibilityLabel("Plan progress")`, `accessibilityValue("\(safeCompleted) of \(progress.total) steps complete")` —
  the value is data, the label is identity. This is the right
  decomposition.
- `accessibilityHint(isComplete ? "Plan complete" : "")` adds the
  semantic only when it fires.
- The new `.accessibilityHidden(true)` on the check `Image` is the
  pass-6 fix — without it, VoiceOver would announce
  "checkmark.circle.fill" *and* the hint, double-talking the same
  state. Pass 6 closes this cleanly.
- `reduceMotion` handling is correctly wired in two places: the
  cluster's `.animation(... value: isComplete)` and the count's
  `.contentTransition(... .numericText() / .identity)`. Both fall
  back to instant. `TahoePillBar` itself also reads `reduceMotion`
  (line 86) and skips its own 0.45s fill — good, the bar's animation
  is independent of the cluster's.
- `.help(...)` provides a pointer-tooltip alternative on Mac that
  states the same value the VoiceOver value reads. No info-only-in-color
  problem.
- Color: at 6/6 the count switches to bold + provider.halo tint. Bold
  weight is the non-color redundancy — even at full color-blindness or
  monochrome screenshots, the bold + check + filled bar are three
  redundant signals.

The iOS variant is structurally identical and inherits the same
accessibility wiring. Symmetric coverage.

### Motion — 10 / 10

Pass 6 fixes the stagger that I would have docked a point for:

- Cluster animation duration is now 0.45s, matching
  `TahoePillBar`'s internal 0.45s ease-in-out (line 123). At 0.25s
  there would have been a visible 200ms tail where the bar was still
  growing after the check + bold-tint cluster had already settled.
  Pass 6 lands them on the same frame.
- `.transition(.scale.combined(with: .opacity))` on the check is the
  right transition for a one-shot milestone — it grows and fades in
  together, not pop-in.
- `.contentTransition(.numericText())` on the count means the
  numerator tumbles digit-by-digit rather than crossfading, which is
  the Tahoe pattern for monospaced counters (matches `TahoeMenuBarMeter`'s
  percent text in spirit, though that one doesn't use
  `.contentTransition`).
- Reduce-motion users get `.identity` and `nil` animations
  throughout. There is no path where a reduce-motion user sees any
  motion.

I considered whether 0.45s is too slow for a sidebar element; it
isn't, because it only fires on `isComplete` toggle (a once-per-plan
event), not on every progress tick.

### Density — 10 / 10

- 6pt bar height + 4pt top padding + 11.5pt iOS / 10.5pt Mac text →
  the bar adds ~14pt to the row's existing footprint. That is the
  minimum visual mass that still reads as "I am a progress bar" at
  laptop viewing distance.
- `minWidth: 44` (Mac) / `48` (iOS) on the count column means the bar
  doesn't reflow as the count digits change. 8/8 and 88/88 land in
  the same right rail. Monospaced digit + min-width is the correct
  pattern.
- The `spacing: 6` between bar / check / count matches the row's
  internal spacing on the status line above (also 6). The new affordance
  inherits the row's rhythm.
- `.frame(maxWidth: .infinity)` on the bar lets it absorb whatever
  width the row gives it. In a narrow sidebar the bar shrinks but the
  count never gets squeezed. Correct prioritization.

### Edge cases — 10 / 10

I already touched these under "state coverage" — repeating the
defensive set for completeness:

- `completed > total` → clamped via `safeCompleted`, never lies.
- `completed < 0` → clamped to 0 by the same expression.
- `total == 0` → denominator clamped to 1 (no div-by-zero); also
  short-circuits `isComplete` because the gate requires
  `progress.total > 0`. So a zero-total plan never glows as complete.
- `progress = nil` → no bar (correct).
- Provider color collapses in dark mode (Codex / Cursor `.deep` is
  near-black) → fixed by using `.halo` for the milestone tint. The
  comment at SessionWorkspaceView.swift:1377-1381 even documents this
  reasoning inline, which is the right place for it.
- Pre-compute race (approved plan, no daemon compute yet) → the wire
  field doesn't populate, so `if let` falls through. Correct.

There is no edge case I can find that's not handled.

---

## Final score

**24 + 20 + 15 + 10 + 10 + 10 + 10 = 99 / 100**

The one withheld quarter-point is for the proof PNG showing Claude
only. The fix is real in code and the tokens are sound — I'm confident
about the Codex/Cursor dark-mode behavior because I read the OKLCH
values directly — but a multi-provider screenshot would have closed it
visually. That's the only thing standing between this and 100.

99/100. Target met.
