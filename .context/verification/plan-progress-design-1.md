# Plan-progress bar — Tahoe design critique (review #1)

Reviewer: independent designer, brutally honest mode.
Artifacts reviewed:

- Screenshot: `.context/verification/plan-progress-bar-mac-final.png` (3 states: 3/8, 6/6, 0/5)
- Mac source: `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:1363-1378`
- iOS source: `apple/ClawdmeteriOS/Tahoe/IOSCodeView.swift:547-562`
- Token surface: `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/TahoeTokens.swift`,
  `TahoeTheme.swift`, `TahoeQuotaBar.swift` (the project's existing bar pattern), `TahoeGlass.swift`
- Wire model: `apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/PlanProgress.swift`

---

## Final Score: 71 / 100

A respectable first cut that uses the right typography, reads cleanly, and ships
working states across both platforms — but it ignores the project's own
established bar pattern (`TahoePillBar`), uses a system-default `ProgressView`
instead of the Tahoe primitives, and leaks a handful of P0-class quality misses
(no idle/finished color differentiation, count drifts under the bar at narrow
widths, the 0/5 state is indistinguishable from an inert empty box, the Mac copy
uses 9.5pt where the iOS copy correctly uses 10.5pt, and motion is implicit
rather than respecting `reduceMotion`).

Verdict: **does not ship as-is**. Two P0s, four P1s, four P2s detailed below.
A focused 30-minute follow-up gets this to a real 88+.

---

## Component scores

| Dimension          | Score      | Notes |
|--------------------|-----------:|-------|
| Theme match        |  17 / 25   | Uses `t.accent` + `TahoeFont` for the count, but bypasses the project's own `TahoePillBar` and gets the system `ProgressView` look (rounded white track, pinstripe rounding mismatch) instead of the Tahoe capsule + gradient + halo that every other bar in this app uses. |
| Visual hierarchy   |  15 / 20   | Right idea (quiet, subordinate) but the bar is wider than the title text on the partial row and pulls the eye away from "Refactor settlement dedupe". Count is `t.fg3` which is correct, but the bar fill itself is the brightest pixel on the row — louder than the title's `t.fg`. |
| State coverage     |   9 / 15   | 6/6 reads as "done" only because of mental math; the bar uses the same color full or partial. 0/5 is functionally invisible — a flat track plus the count is the only signal there's anything there. |
| Accessibility      |   7 / 10   | A11y label + value are correct and combined. No `accessibilityHint` on what "plan progress" means. No reduce-motion check on the implicit `ProgressView` value animation. No explicit support for high-contrast. |
| Motion             |   5 / 10   | Implicit `ProgressView` value-update animation works but is uncontrolled (system default, ~0.2s) and ignores `accessibilityReduceMotion`. No transition when the bar first appears (post-approval pop is a jump-cut). |
| Density            |   8 / 10   | `.padding(.top, 2)` on Mac is the right call; row grows ~10pt taller, which is acceptable on a workspace sidebar. iOS uses `.padding(.top, 3)` instead — a stylistic inconsistency, not a sin. |
| Edge cases         |  10 / 15*  | Wire layer caps at 24 (good). `0/0` is gated to nil in `PlanProgress.from(steps:)`. But 1/1 isn't visually distinct from 6/6 (both look full), 24/24 + a long city subtitle pushes layout, and a locale that renders digits wider than `9.5pt` monospaced would clip on Mac. *Scoring caps at 10 per the rubric — the slip costs ~3 points within the 10-point ceiling.* |

Total: 71 / 100.

---

## Findings

### P0 — blocking

**P0-1. The bar isn't actually a Tahoe bar.**

`ProgressView(value:).progressViewStyle(.linear).tint(t.accent)` on macOS renders
the AppKit system bar: a slightly rounded white-tinted track, system-chosen
height (~4pt on Mac, ~2pt on iOS, *different on the two platforms*), and no
provider color, no halo, no gradient. Every other bar in this codebase —
`TahoeQuotaBar`, `TahoePillBar`, `TahoeMenuBarMeter` — uses
`TahoePillBar(percent:provider:height:)` which paints a Tahoe capsule, a
`LinearGradient(provider.halo → provider.glow)`, and a 5pt halo shadow.

The proof screenshot shows this directly: the partial bar fill is a flat
salmon (`t.accent` = `OKLCH(0.72, 0.16, 40)` for the ember accent? — no, the
default is `.halo` which is *blue*. The screenshot shows orange, which means
this surface is being read with an `ember` accent in TahoeThemeStore OR the
`session.agent.tahoeProvider` halo color is leaking through somewhere. Either
way, it's a flat fill with no gradient and no shadow, which violates the
Tahoe identity.

Files: `SessionWorkspaceView.swift:1364-1368`, `IOSCodeView.swift:548-552`

Fix (Mac, replace lines 1364-1373):

```swift
if let progress = session.planProgress {
    HStack(spacing: 6) {
        TahoePillBar(
            percent: progress.fraction * 100,
            provider: session.agent.tahoeProvider,
            height: 4
        )
        .frame(maxWidth: .infinity)
        Text("\(progress.completed)/\(progress.total)")
            .font(TahoeFont.body(10.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(t.fg3)
    }
    .padding(.top, 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Plan progress")
    .accessibilityValue("\(progress.completed) of \(progress.total) steps complete")
    .accessibilityHint("Daemon-computed progress against the approved plan")
}
```

Mirror the same change at `IOSCodeView.swift:547-562` (already uses 10.5pt — just
swap `ProgressView` for `TahoePillBar`).

This single change moves Theme match from 17→23 and Visual hierarchy from 15→18.

---

**P0-2. Mac and iOS use different label sizes for the same control.**

Mac line 1370: `TahoeFont.body(9.5, weight: .semibold)`.
iOS line 554: `TahoeFont.body(10.5, weight: .semibold)`.

9.5pt is below the rest of the Mac row's typography floor (subtitle is 10.5pt
at `SessionWorkspaceView.swift:1346`). The count looks pinched on Mac and
correct on iOS — which means one of them is wrong, not "appropriate per
platform". 10.5pt matches the row's existing density on both surfaces.

Fix (Mac, line 1370):

```swift
.font(TahoeFont.body(10.5, weight: .semibold))
```

---

### P1 — quality

**P1-1. 6/6 doesn't read as "done"; 0/5 reads as "broken".**

The bar fill is `t.accent` (or provider halo) at every fraction including 1.0.
Visually a full bar and a 5/6 bar look the same color; only the count
disambiguates them. And at `0/5` the bar collapses to *nothing* — the user
sees an empty pale rectangle and a count, which looks like a render bug, not
a deliberate state.

Fix: introduce three explicit visual states. On Mac
`SessionWorkspaceView.swift:1364-1373`:

```swift
if let progress = session.planProgress {
    let isComplete = progress.completed >= progress.total && progress.total > 0
    let isEmpty    = progress.completed == 0
    HStack(spacing: 6) {
        TahoePillBar(
            percent: isEmpty ? 100 : progress.fraction * 100,  // empty: render hairline track only
            provider: session.agent.tahoeProvider,
            height: 4
        )
        .opacity(isEmpty ? 0 : 1)               // hide the gradient when 0/N
        .overlay(alignment: .leading) {
            if isEmpty {
                Capsule(style: .continuous)
                    .stroke(t.hairline, lineWidth: 0.5)
                    .frame(height: 4)
            }
        }
        .saturation(isComplete ? 1.1 : 1.0)     // brighten on complete
        .frame(maxWidth: .infinity)
        Text("\(progress.completed)/\(progress.total)")
            .font(TahoeFont.body(10.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(isComplete ? t.fg2 : t.fg3)   // complete = stronger
    }
    .padding(.top, 3)
    // …accessibility unchanged
}
```

Alternative (simpler): when complete, swap the gradient for the deep accent
(`session.agent.tahoeProvider.deep.color`) so 6/6 reads as a saturated solid
strip and `5/6` reads as a gradient. The verifier can confirm by diffing
the 6/6 row against the 5/6 row pixel-for-pixel.

For `0/N`: render a hairline-stroked empty capsule so the user can tell
"a bar exists, it's at zero" vs "no plan progress yet".

---

**P1-2. Motion ignores `accessibilityReduceMotion`.**

The implicit `ProgressView` value animation is OS-driven; we don't control
duration or whether it runs at all. `TahoePillBar.body` already has
`.animation(.easeInOut(duration: 0.45), value: percent)` — when we swap to
that primitive (P0-1), wrap it in the project's reduce-motion check the same
way `SessionWorkspaceView` already does at line 245, 3343, 3416, 4254, 4631.

Inside `TahoePillBar.body`, the existing `.animation(.easeInOut(duration:
0.45), value: percent)` at `TahoeQuotaBar.swift:119` needs the reduce-motion
guard:

```swift
.animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: percent)
```

…and add `@Environment(\.accessibilityReduceMotion) private var reduceMotion`
at the top of `TahoePillBar`. (This is a shared-primitive fix — benefits every
quota bar in the app, not just plan progress.)

File: `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/TahoeQuotaBar.swift:119`

---

**P1-3. The count number drifts under the bar in narrow sidebars.**

`Text("\(progress.completed)/\(progress.total)")` with `monospacedDigit()` is
correct, but at narrow column widths the bar's `.frame(maxWidth: .infinity)`
consumes the space and the count squeezes into ~22-28pt — `124/240` (the
future-cap-raise edge case) wraps or truncates.

Fix: reserve a minimum width for the count so the bar is the only thing that
flexes. Mac `SessionWorkspaceView.swift:1369`:

```swift
Text("\(progress.completed)/\(progress.total)")
    .font(TahoeFont.body(10.5, weight: .semibold))
    .monospacedDigit()
    .foregroundStyle(t.fg3)
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
    .frame(minWidth: 34, alignment: .trailing)
```

Same change at iOS line 553.

---

**P1-4. No appearance transition when the bar first lands.**

Right after the user taps "Approve plan", the bar pops in mid-row without a
transition. Adds visual jank on a surface that's otherwise smooth.

Fix: wrap the conditional in a transition. Mac line 1363:

```swift
Group {
    if let progress = session.planProgress {
        // …bar HStack as in P0-1
    }
}
.transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
.animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: session.planProgress != nil)
```

Plus `@Environment(\.accessibilityReduceMotion) private var reduceMotion` in
the enclosing view if it's not already there (line 36 in `SessionWorkspaceView`
already declares it on the parent type — confirm it's in scope inside `sessionRow`).

---

### P2 — polish

**P2-1. The track color for `0/N` borrows from `ProgressView`'s system grey.**

The screenshot's 0/5 bar shows a flat very-light-pink/grey rectangle that
doesn't match any Tahoe hairline token. After P0-1, the track will be the
Tahoe `Color(.sRGB, white: 1, opacity: 0.12)` (dark mode) or
`Color(.sRGB, white: 15/255, opacity: 0.08)` (light mode) per `TahoePillBar`
— consistent across the app. Verified in `TahoeQuotaBar.swift:99-101`.

No code change beyond P0-1.

---

**P2-2. Count weight could be lighter when partial, heavier when complete.**

Currently `.semibold` always. Subtle improvement: `.regular` for partial,
`.semibold` for complete or zero. This reinforces the state hierarchy without
shouting.

Fix (Mac line 1370):

```swift
.font(TahoeFont.body(10.5, weight: isComplete || isEmpty ? .semibold : .regular))
```

---

**P2-3. No tooltip on Mac.**

Hovering the bar should reveal what it represents — Mac convention is `.help()`.

Fix (Mac, append to the HStack at line 1364-1373):

```swift
.help("\(progress.completed) of \(progress.total) plan steps complete · last checked \(progress.lastComputedAt, style: .relative)")
```

iOS doesn't have hover; long-press accessibility is already covered.

---

**P2-4. Mac uses `.padding(.top, 2)`; iOS uses `.padding(.top, 3)`.**

A 1pt density inconsistency between platforms for the same surface. Both
should match the row's existing `spacing: 2` (VStack) ethos, but the bar
deserves slightly more breathing room than other inner content because it
ends a content block. Settle on `3` on both.

Fix (Mac line 1374):

```swift
.padding(.top, 3)
```

---

## What's strong

- **Wire-layer design is excellent.** `PlanProgress.from(steps:)` returning
  `nil` for the empty case (instead of `0/0`) is exactly right — the UI
  contract is "no plan progress = no bar" and the model enforces it. The
  24-step cap is documented at the model layer, not patched into the views.
- **A11y is real**, not theater: `accessibilityElement(children: .combine)`
  + `accessibilityLabel` + `accessibilityValue` covers VoiceOver correctly.
  Just missing a hint.
- **Typography on iOS is right.** `TahoeFont.body(10.5, weight: .semibold)`
  + `monospacedDigit()` is the correct call for a count next to a bar.
- **`t.fg3` for the count is the right hierarchy choice.** Subordinate to
  the title's `t.fg`, lighter than the subtitle's `t.fg3` is fine since
  they live in different rows of the VStack.
- **Density discipline is sound.** Adding ~10pt to a row with a plan is
  proportional and avoids the "every row grows" anti-pattern.

## What's weak

- **System `ProgressView` instead of the project's own `TahoePillBar`.** This
  is the single biggest miss — the codebase already solved this problem twice
  (`TahoeQuotaBar` + `TahoePillBar`) and the plan-progress bar doesn't use
  either. Result: a flat fill, no provider gradient, no halo, no Tahoe
  capsule rounding, no controlled motion. Looks like a placeholder, not a
  finished surface.
- **0/N is indistinguishable from a render failure.** A flat empty rectangle
  with `0/5` next to it reads as broken, not as "just approved".
- **6/6 doesn't celebrate completion.** No color shift, no weight shift on
  the count. The whole point of a progress bar is to mark the transition
  from "in flight" → "done"; this one doesn't.
- **Mac/iOS aren't pixel-equivalent.** 9.5 vs 10.5pt label, 2 vs 3pt top
  padding. Small but indicative — a designer would treat them as one
  component.
- **Motion is uncontrolled.** No reduce-motion guard, no first-appear
  transition.

---

## Suggested patch order

1. **P0-1** (swap `ProgressView` → `TahoePillBar`) — 10 minutes. Single biggest
   uplift.
2. **P0-2** (Mac font 9.5 → 10.5) — 30 seconds.
3. **P1-1** (state differentiation: empty, partial, complete) — 15 minutes.
4. **P1-2** (`reduceMotion` in `TahoePillBar`) — 5 minutes. Improves every
   bar in the app.
5. **P1-3** (count minWidth) — 2 minutes.
6. **P1-4** (appearance transition) — 5 minutes.
7. P2 polish — 10 minutes.

Total: ~50 minutes to reach 88-92.
