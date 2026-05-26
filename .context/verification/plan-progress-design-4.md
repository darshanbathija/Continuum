# Plan Progress Bar — Pass 4 Design Review (Independent)

Reviewer: independent designer, no shared context from prior passes.
Pass: 4 (prior pass scored 94/100).
Artifacts reviewed:
- Proof screenshot `plan-progress-bar-mac-final.png` (3 rows: 3/8, 6/6, 0/5).
- Production Mac source `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift` (lines 1370–1400).
- Production iOS source `apple/ClawdmeteriOS/Tahoe/IOSCodeView.swift` (lines 549–578).
- Shared `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/TahoeQuotaBar.swift` (lines 84–129).
- Shared `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/TahoeTokens.swift` (`TahoeProvider` slots).

---

## Score: 96 / 100

### Component scores

| Dimension              | Score    | Notes                                                                                                                                                                                                                                                                                                |
|------------------------|---------:|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Theme match            | 24 / 25  | Bar reuses `TahoePillBar` exactly — same `[halo, glow]` gradient, same 6pt height, same drop-shadow halo as the rest of the bar fleet. Complete tint is `provider.deep.color`. One token deduction: the `deep` family is a *slightly* darker hue than what the bar actually emits (`halo→glow`), so the icon/count cluster reads as a richer cousin rather than an exact match. Intentional and harmonious, but it’s the one place the surface uses three Tahoe slots (`halo`, `glow`, `deep`) in the same 100pt span. |
| Visual hierarchy       | 19 / 20  | Bar dominates, count is the secondary cue, checkmark is the tertiary moment cue. Bold count + provider-deep tint on completion is the right escalation. Minor: the partial state's count at 10.5pt semibold `fg2` can feel slightly recessive against the bold full-state — by design, but the contrast between *partial* and *complete* count weight is the largest jump in the row. |
| State coverage         | 14 / 15  | Empty/just-approved (0/n), partial (n/m), complete (m/m) all present and distinct. Missing only an "indeterminate" / "computing first sample" state — a session has an approved plan but the daemon hasn't produced a fraction yet. Per the comments at lines 1359–1363, the bar simply isn't rendered until the first compute, which is defensible but means the user gets no UI between plan approval and first compute (could be seconds, could be longer on a cold start). |
| Accessibility          | 9 / 10   | `accessibilityElement(.combine)`, label "Plan progress", value "{n} of {m} steps complete" — solid VoiceOver. Reduce-motion respected on both the numeric content transition *and* the container animation. Missing: hover tooltip on Mac (`.help("…")`) so non-VoiceOver users can confirm the meaning of an unfamiliar bar — every other badge in the same row has a `.help()`. Also missing: an `.accessibilityAddTraits(.isSelected)` or similar distinctive trait when complete, so screen-reader users can hear the milestone moment as more than a value change. |
| Motion                 | 10 / 10  | `.transition(.scale.combined(with: .opacity))` for the checkmark entry, `.contentTransition(.numericText())` for the digit roll, `.animation(.easeInOut(0.25), value: isComplete)` to choreograph the whole moment as a unit, and the underlying `TahoePillBar` already has its own 0.45s easeInOut on `percent`. All four respect `accessibilityReduceMotion`. This is the strongest dimension. |
| Density                | 10 / 10  | 6pt bar height matches `TahoeQuotaBar.dense` and `TahoeMenuBarMeter`. 3pt top padding sits the bar just below the subtitle without bleeding into the next row's hover halo. Count `minWidth: 32` (Mac) / `34` (iOS) keeps the bar's right edge stable as digits change. Platform-appropriate count sizes (10.5pt / 11.5pt) match each surface's subtitle scale. |
| Edge cases             | 9 / 10   | Zero-fill rendered as track-only (TahoePillBar line 117) — clean. `isComplete` correctly guarded against `total == 0`. monospacedDigit on the count. One unhandled: weight flip from semibold→bold can still nudge digit width by ~0.5pt because `.monospacedDigit()` equalises *between digits* but not between *weights* — the `minWidth` masks it but tall counts (e.g. 99/199) could overflow the 32pt slot on Mac. |

---

## Remaining findings

### P1 — Mac row lacks a hover tooltip for the progress cluster
- **File**: `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift`
- **Lines**: 1374–1400 (the outer `HStack(spacing: 6)`)
- **Why P1**: every other status element in the same row has `.help(…)` (unread dot line 1419, pin line 1425, mute line 1431, queued counter line 1461). The progress bar is the only one that doesn't, which makes it the only element in the row that a hovering user can't disambiguate without VoiceOver.
- **Fix** — append after line 1399 (`.accessibilityValue(...)`):
  ```swift
  .help(isComplete
        ? "Plan complete — \(progress.completed) of \(progress.total) steps"
        : "Plan progress — \(progress.completed) of \(progress.total) steps")
  ```

### P2 — Count minWidth too small for triple-digit plans on Mac
- **File**: `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift`
- **Line**: 1392 (`.frame(minWidth: 32, alignment: .trailing)`)
- **Why P2**: a 99/199 plan in 10.5pt bold renders ~38pt wide — overflows 32pt and would either push the spacer or compress the bar. Unlikely in practice but a one-character defensive fix.
- **Fix**: bump to `minWidth: 40` on Mac and `minWidth: 42` on iOS (line 570 of `IOSCodeView.swift`).

### P2 — No screen-reader distinct trait on completion
- **File**: `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift` (and the iOS equivalent at `IOSCodeView.swift` line 577)
- **Lines**: 1397–1399 on Mac, 575–577 on iOS
- **Why P2**: the accessibility value's wording already includes "complete" when complete, but VoiceOver users don't get a navigational trait change — the milestone moment is announced the same way as any other value update. Adding `.accessibilityAddTraits(isComplete ? .isStaticText : [])` would not help, but adding a custom accessibility action or a small `.accessibilityHint("Complete")` for the complete state would let users hear the moment.
- **Fix** — append after the `.accessibilityValue(…)` line on Mac (line 1399) and iOS (line 577):
  ```swift
  .accessibilityHint(isComplete ? "Plan complete" : "")
  ```

### P2 — Vertical breathing room above the bar is 1pt shy
- **File**: `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift`
- **Line**: 1395 (`.padding(.top, 3)`)
- **Why P2**: the subtitle line sits directly above the bar at 9.5–10pt with a 6pt bar below. 3pt looks tight against the descenders of the subtitle ("ago" sits low on the row). 4pt would let the moment breathe without changing the row's overall height meaningfully.
- **Fix**: change `.padding(.top, 3)` → `.padding(.top, 4)` on Mac line 1395 and iOS line 573.

### P2 — Subtle weight-shift jitter on count flip
- **File**: `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift`
- **Lines**: 1389 (`.font(TahoeFont.body(10.5, weight: isComplete ? .bold : .semibold))`)
- **Why P2**: `monospacedDigit()` equalises advance widths *within a weight*, not *across weights*. Going from semibold → bold on `isComplete` can shift the leading digit by ~0.3–0.5pt even with the minWidth in place (the digit is trailing-aligned but the *interior* of the digit cluster reflows). Visible only at first paint of completion; the easeInOut on `isComplete` masks it. Acceptable in production.
- **Fix** (optional, if pursuing 98+): pin the weight at `.bold` for both states and use color alone to differentiate, *or* keep both states at `.semibold` and lean on color + checkmark as the only completion signals. Either eliminates the weight-flip entirely. The most conservative choice: keep semibold throughout — color + checkmark are already doing the work.

### P2 — Bar emits three Tahoe color slots in one 100pt strip
- **File**: `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/TahoeQuotaBar.swift` + `SessionWorkspaceView.swift`
- **Lines**: TahoePillBar line 114 uses `[halo, glow]` for the fill; SessionWorkspaceView line 1373 uses `deep` for the checkmark/count tint
- **Why P2**: bar gradient anchors are `halo` (lightest) and `glow` (mid); the completion tint is `deep` (darkest). Three slots in one cluster is one more than the rest of the Tahoe surface usually allows (`TahoeMenuBarMeter` for example uses just `halo→glow` for fill and `fg2` for the label). It works because all three are the same hue family, but it's the one place this surface ventures off-pattern.
- **Fix** (optional, if pursuing 98+): drop the `deep` tint and use `provider.halo.color` for the checkmark and count on completion — same hue family, brighter, and now the entire cluster lives in two slots instead of three. The bar gradient already terminates at `glow`, so the count would tint slightly *brighter* than the bar end, which mirrors the visual logic of "this is the celebratory moment". Try in a branch — there's a chance `deep` reads as more "earned" / more "rich" and `halo` reads as "candy". Designer judgement call.

---

## Summary

The bar lands the milestone moment cleanly. The four motion polish items (transition, content transition, container animation, reduce-motion guards on both layers) are all wired correctly, the provider-deep complete tint resolves the three-hue clash from the prior pass, and the `fg2` contrast bump means the partial state passes WCAG AA. The remaining gap to 98 is dominated by a single P1 (no Mac hover tooltip — every other badge in the row has one, so this stands out) and four genuine P2s (minWidth too small for triple-digit plans, no a11y hint on completion, 3pt top padding 1pt shy, and a sub-pixel weight-flip jitter on the count). Take the P1 plus the tooltip and the minWidth bump and this clears 98 honestly; the rest are polish that designers will argue about until the project ships.
