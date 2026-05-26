# Plan Progress Bar — Design Critique, Pass 2

**Independent designer pass. No shared context with pass 1.**

## Score: 91 / 100

(Honest. 91 is not 92. Pass 1 was 71; this iteration closes every P0 and most P1s but leaves three real, fixable gaps — one of which is an accessibility regression hidden inside a shared primitive.)

## Component scores

| Dimension          | Score    | Notes                                                                                                                                                                                                                          |
| ------------------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Theme match        | 24 / 25  | Uses `TahoePillBar` + `tahoeProvider` + `TahoeFont.body(10.5)` + `t.fg3` / `t.accent`. 5pt height is tighter than the 6pt fleet baseline — intentional for sidebar density and reads well, but technically a one-off value.   |
| Visual hierarchy   | 18 / 20  | Bar reads subordinate to title; count is quiet at 10.5pt semibold neutral. Complete state bumps to bold + accent — payoff lands. -2: the 6/6 row's bar visually dominates the row at full width (no right-side gutter).        |
| State coverage     | 14 / 15  | 0/N capsule background visible (was invisible in pass 1). Partial fills smoothly. Complete state visually distinct via bold + accent. -1: 0/N count is still `.semibold` on `t.fg3` — same as partial — only the bar differs.  |
| Accessibility      | 6 / 10   | `.accessibilityElement(children: .combine)` + label + value present and well-worded. **-4: `TahoePillBar` ignores `accessibilityReduceMotion`** — animates 0.45s easeInOut unconditionally (line 119). Dark mode capsule fine. |
| Motion             | 7 / 10   | Smooth 0.45s easeInOut feels right for a progress fill. -3: same reduceMotion issue. Also: agent change mid-session animates color through an interpolated gradient — looks fine on screen but not gated either.              |
| Density            | 8 / 10   | 3pt top pad + 5pt bar + 10.5pt count = a tight ~18.5pt stripe. Doesn't crush the row. -2: when the bar is absent, neighboring rows are visibly shorter; the layout doesn't reserve the slot, so the list "jumps" as plans land. |
| Edge cases         | 9 / 10   | 1/1 → bold + accent works. 24/24 fits the 32pt min-width. Dark mode tint inherits via provider.halo. -1: long locale token strings ("Complete 24 of 24") are not visible because the count text isn't localized.              |

## Findings

### P0 — block ship

_None._ All pass-1 P0s are addressed. No new blockers.

### P1 — quality

**P1-1: `TahoePillBar` does not honor `accessibilityReduceMotion`.**
- File: `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/TahoeQuotaBar.swift:119`
- Issue: The fill capsule has `.animation(.easeInOut(duration: 0.45), value: percent)` unconditionally. Users with Reduce Motion enabled get the animation anyway. Every call site that uses `TahoePillBar` (the new plan-progress rows, the menu-bar meter, the quota orb in dense mode) inherits this regression.
- Fix (one line on the primitive — fixes every call site at once):
  ```swift
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // ...
  .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: percent)
  ```
  Add the `@Environment` declaration to `TahoePillBar`'s body (line 85, alongside `t`).

**P1-2: iOS subtitle ↔ count typography is mismatched.**
- File: `apple/ClawdmeteriOS/Tahoe/IOSCodeView.swift:541-557`
- Issue: iOS subtitle is `TahoeFont.body(11.5)` (line 542). Progress count is `TahoeFont.body(10.5, …)` (line 557). On Mac both are 10.5 — they match. On iOS the count is 1pt smaller than the subtitle directly above it, breaking the row's typographic rhythm. Pass 1's "10.5pt floor" rule was applied uniformly without checking the iOS row's actual subtitle size.
- Fix: bump iOS count to match the iOS subtitle scale:
  ```swift
  .font(TahoeFont.body(11.5, weight: isComplete ? .bold : .semibold))
  ```

### P2 — polish

**P2-1: Bar reserves no space when absent → list jumps when plans land.**
- File: `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:1369-1388` (and iOS twin)
- Issue: `if let progress = …` conditionally renders the entire stripe, so a row grows by ~18.5pt the instant `PlanProgressTracker` emits its first compute. In a long sidebar this causes visible reflow.
- Fix (cheapest): give the slot a fixed reservation by always rendering an empty Color frame of the same height when `planProgress` is nil:
  ```swift
  if let progress = session.planProgress { /* current block */ }
  else { Color.clear.frame(height: 18.5).padding(.top, 3) }
  ```
  Better: gate the row's whole `VStack(spacing:)` so rows with vs without plans are visually consistent.

**P2-2: Count string not localized.**
- File: `SessionWorkspaceView.swift:1378`, `IOSCodeView.swift:556`
- Issue: `Text("\(progress.completed)/\(progress.total)")` is fine in English, but the accessibility value already uses "X of Y" — translated locales (de, fr, ja) prefer locale-specific separators. Voice-over already says "X of Y steps complete" correctly; only the visible glyph is hardcoded.
- Fix:
  ```swift
  Text("\(progress.completed)/\(progress.total)", comment: "Plan progress: completed/total")
  ```
  (Marks the string for `genstrings` extraction without changing visible output for en.)

**P2-3: Complete-state payoff is single-axis (color + weight).**
- File: `SessionWorkspaceView.swift:1379-1381`, `IOSCodeView.swift:557-559`
- Issue: At 100% the count goes bold + accent and the bar is fully filled. Reads correctly. But the bar itself doesn't get any "done" affordance — same halo, same shadow. Consider a subtle checkmark glyph or 100% bar capping the right edge with a slightly heavier ring. Low priority; current solution is legible.
- Fix (optional): add a `Image(systemName: "checkmark")` 9pt to the right of the count when `isComplete`.

**P2-4: 5pt bar height is one-off vs the fleet's 6pt baseline.**
- File: both call sites — `height: 5`
- Issue: `TahoePillBar`'s default is 6 and every other consumer (TahoeQuotaBar dense, TahoeMenuBarMeter) uses 6. The 5pt choice is a one-off for sidebar density. It works visually, but if the project documents a height token it should land in `Theme.swift` rather than hardcoded numbers in two views.
- Fix: define `static let pillBarHeightDense: CGFloat = 5` on `Theme` (or `TahoeFont`-adjacent constants) and reference at call sites.

## Summary

This iteration cleanly addresses every pass-1 P0 — the bar is now the project's `TahoePillBar` primitive with provider tint, the Mac/iOS typography is unified at 10.5pt, the count has a 32pt min-width, the 6/6 complete state bumps to bold + `t.accent` (legitimate payoff), and 0/5 shows its capsule background. The screenshot reads exactly as the design intent describes. The 9-point deduction is for one real accessibility regression and two density/locale gaps: `TahoePillBar` itself unconditionally animates and silently ignores `accessibilityReduceMotion`, the new iOS row's count is 1pt smaller than the subtitle above it (Mac is fine, iOS isn't), and the list jumps as plans land because the bar slot isn't reserved. Fix P1-1 on the shared primitive and the score moves to 95+.
