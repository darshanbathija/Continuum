# Plan Progress Bar — Design Pass 3

**Reviewer**: independent designer, no shared context with passes 1–2.
**Surface**: SessionWorkspaceView (Mac) + IOSCodeView (iOS) `if let progress = …planProgress` block.
**Theme**: Tahoe.
**Artifact**: `/Users/darshanbathija_1/Downloads/CC Watch/Clawdmeter-worktrees/plan-progress-bar/.context/verification/plan-progress-bar-mac-final.png` (three rows: 3/8 partial, 6/6 complete with checkmark, 0/5 just-approved).

---

## Final Score

**94 / 100**

Below the 98 bar. The reduceMotion guard, per-platform typography parity, height-to-fleet, and the checkmark add-on are all in. Remaining gaps are visual polish (checkmark/halo seam, unanimated checkmark pop), a cross-provider chromatic clash on the count color, and a missing low-percentage signal for the 0/N just-approved state.

---

## Component Scores

| Dimension | Score | Notes |
|---|---|---|
| Theme match | **25 / 25** | TahoePillBar primitive used; AgentKind.tahoeProvider on Mac, TahoeProvider directly on iOS; TahoeFont throughout; t.fg3 / t.accent tokens; 6pt bar height matches fleet (TahoeMenuBarMeter, TahoeQuotaBar dense); 3pt top padding; 10.5pt on Mac (matches Mac subtitle 10.5pt), 11.5pt on iOS (matches iOS subtitle 11.5pt). |
| Visual hierarchy | **18 / 20** | Title bold > status > bar > count fg3 (subordinated correctly). 100% promotes count to bold accent + checkmark icon — real dual-axis payoff. Deducted 2pt: the checkmark.circle.fill sits flush against the bar's right halo shadow in the 6/6 row; the accent-orange icon optically blends with the provider-orange halo, blurring the distinction between bar terminus and icon. |
| State coverage | **14 / 15** | Three states visually distinct: empty pill (0/N), gradient fill (partial), full gradient + checkmark + accent count (complete). Deducted 1pt: 0/N state has zero color — looks identical to a "plan not loaded" inactive surface. The "0/5" text label disambiguates, but a 0% bar still reads as "no signal" rather than "approved, awaiting first step." |
| Accessibility | **9 / 10** | `.accessibilityElement(children: .combine)` + `accessibilityLabel("Plan progress")` + `accessibilityValue("\(completed) of \(total) steps complete")` correctly authored. ReduceMotion guard at `TahoeQuotaBar.swift:123-124` lifts the whole pill-bar fleet. Dark mode capsule track flips to white-12%. Deducted 1pt: t.fg3 partial-state count at 10.5pt (Mac) computes to ~46% opacity black on near-white — approximately 3.8:1 contrast, below WCAG 4.5:1 for body text. Bar carries the info so it's not a blocker, but it's a real measurement. |
| Motion | **9 / 10** | TahoePillBar 0.45s easeInOut on percent change, gated by reduceMotion. Deducted 1pt: the checkmark icon's appearance at the 99→100 transition is *not* animated — it pops in with no transition. A `.transition(.scale.combined(with: .opacity))` would polish the milestone moment; should be gated by reduceMotion. |
| Density | **9 / 10** | 6pt bar + 3pt top pad = 9pt addition, only on plan-progress rows. ~30% row-height growth on Mac (12pt title row baseline), proportionally larger than iOS but tolerable since it appears only on the subset of sessions with an approved plan. Deducted 1pt: the 3pt top pad puts the bar quite close to the status subtitle line on Mac at 10.5pt; could justify 4pt for breathing room. |
| Edge cases | **10 / 10** | 1/1 fits the 32pt minWidth ✓; 24/24 fits ✓; dark mode capsule track flips correctly ✓; agent change mid-session works because tahoeProvider is value-typed and recomputes per render ✓; "X/Y" is symbol-only and locale-safe ✓. The cross-provider chromatic clash (provider-tinted bar + t.accent checkmark/count) is *covered* under Visual Hierarchy above so I don't double-count it here. |

**Total: 25 + 18 + 14 + 9 + 9 + 9 + 10 = 94 / 100.**

---

## Findings

### P0
None.

### P1
None.

### P2-1: checkmark.circle.fill optically blends with bar's right halo

**File:** `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:1378-1382`
**File:** `apple/ClawdmeteriOS/Tahoe/IOSCodeView.swift:556-560`
**Observed in screenshot:** Row 2 (6/6) — the accent-colored checkmark sits flush against the bar's right edge, where TahoePillBar emits a `.shadow(color: provider.halo.color(opacity: 0.45), radius: 5)`. On Claude (orange brand), the orange halo bleeds under the orange-ish accent checkmark, so the eye reads them as one continuous blob instead of "bar reaches 100% AND there's a milestone icon."

**Fix (Mac):** bump the leading inset on the checkmark when complete so the halo's outer ring tapers off before the icon starts. Replace
```swift
HStack(spacing: 6) {
    TahoePillBar(...)
    .frame(maxWidth: .infinity)
    if isComplete {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(t.accent)
    }
```
with
```swift
HStack(spacing: 6) {
    TahoePillBar(...)
    .frame(maxWidth: .infinity)
    if isComplete {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(t.accent)
            .padding(.leading, 2) // separate from bar halo
    }
```

**Fix (iOS):** same change at `IOSCodeView.swift:557-560`, font size 11.

### P2-2: 100% milestone icon has no entry animation

**File:** `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:1378-1382`
**File:** `apple/ClawdmeteriOS/Tahoe/IOSCodeView.swift:556-560`

When `progress.completed` flips from N-1 to N, the bar smoothly animates from ~95% to 100% (0.45s easeInOut), and simultaneously the checkmark and the count both *instantly* change appearance — count weight flips from `.semibold` to `.bold`, color flips from `t.fg3` to `t.accent`, and the icon pops in with no transition. This breaks the temporal continuity established by the bar's animation: the user sees a smooth bar fill, then a hard cut to the payoff state.

**Fix:** wrap the conditional checkmark in `.transition` and let the parent HStack pick up the animation on the same `value` as the bar.

Mac (lines 1369-1393):
```swift
if let progress = session.planProgress {
    let isComplete = progress.completed >= progress.total && progress.total > 0
    HStack(spacing: 6) {
        TahoePillBar(
            percent: progress.fraction * 100,
            provider: session.agent.tahoeProvider,
            height: 6
        )
        .frame(maxWidth: .infinity)
        if isComplete {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(t.accent)
                .padding(.leading, 2)
                .transition(.scale.combined(with: .opacity))
        }
        Text("\(progress.completed)/\(progress.total)")
            .font(TahoeFont.body(10.5, weight: isComplete ? .bold : .semibold))
            .monospacedDigit()
            .foregroundStyle(isComplete ? t.accent : t.fg3)
            .frame(minWidth: 32, alignment: .trailing)
            .contentTransition(.numericText())  // smooth count rollover
    }
    .padding(.top, 3)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45),
               value: isComplete)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Plan progress")
    .accessibilityValue("\(progress.completed) of \(progress.total) steps complete")
}
```

This requires adding `@Environment(\.accessibilityReduceMotion) private var reduceMotion` at the top of `SessionWorkspaceView` (line ~12, near other `@Environment` declarations) and `IOSRepoCard` (`IOSCodeView.swift:478`).

iOS mirror: same change at lines 547-571, font size 11 on the icon, minWidth 34 on the count.

### P2-3: cross-provider chromatic mismatch on the completed count

**File:** `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:1381,1386`
**File:** `apple/ClawdmeteriOS/Tahoe/IOSCodeView.swift:559,564`

At 100%, the bar gradient is provider-tinted (`provider.halo.color` → `provider.glow.color`), but the checkmark and the count are `t.accent` — the **user's** configured accent, which defaults to terracotta. On a Claude session this happens to look unified (Claude's halo is orange, terracotta is orange-ish), but on a Codex session you get an OpenAI-blue bar with a terracotta checkmark + terracotta "24/24" sitting next to it. Three hues for one row.

This is *defensible* as a Tahoe convention ("system accent = positive milestone"), but at the 98+ bar I'd reach for provider-tint continuity here. Counterargument: at 100% the bar is fully provider-tinted, so a provider-tinted count would just amplify the same hue twice. Either way it's a real taste call worth flagging.

**Recommended fix** (provider-consistent payoff): use the provider's deep color for the count at 100% so the row reads as a single chromatic family.

Mac:
```swift
if isComplete {
    Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(session.agent.tahoeProvider.deep.color)  // was t.accent
        .padding(.leading, 2)
}
Text("\(progress.completed)/\(progress.total)")
    .font(TahoeFont.body(10.5, weight: isComplete ? .bold : .semibold))
    .monospacedDigit()
    .foregroundStyle(isComplete ? session.agent.tahoeProvider.deep.color : t.fg3)
    .frame(minWidth: 32, alignment: .trailing)
```

iOS mirror at lines 559 and 564, using `s.agent.deep.color`.

If the team disagrees and wants to keep `t.accent` (the "this is a user-recognized milestone" pattern), keep as-is — but at least flag this so it's a deliberate choice.

### P2-4: 0/N just-approved state has no chromatic signal

**File:** `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:1372-1376` and `apple/ClawdmeteriOS/Tahoe/IOSCodeView.swift:550-554`
**Indirect file:** `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/TahoeQuotaBar.swift:116-117`

At percent=0, `TahoePillBar` renders only the gray capsule track (the fill capsule has zero width). Visually, "approved but not yet started" looks identical to "no plan / no signal." The "0/5" text label disambiguates, but the bar itself contributes no chromatic information at this state.

**Two viable fixes** (no consensus pick — depends on whether the team treats 0/N as a privileged state):

*Option A — leading dot:* render a 2pt provider-tinted leading dot at 0% (same color as the gradient start) to signal "this is an active plan, just not started yet."

```swift
// In TahoeQuotaBar.swift, replace lines 113-117 with:
.fill(LinearGradient(
    colors: [provider.halo.color, provider.glow.color],
    startPoint: .leading, endPoint: .trailing))
.frame(width: percent > 0
    ? max(geo.size.width * percent / 100, max(height, 4))
    : max(height, 4))  // always show at least a leading pip
.opacity(percent > 0 ? 1 : 0.55)  // half-tone the 0% pip so partial states still dominate
```

*Option B — no change:* accept that the explicit "0/5" text label is sufficient signal and keep the empty capsule. This is what most progress UIs do.

Recommendation: ship Option A only if a designer has reviewed it in context with the rest of the sidebar. The risk is that the pip becomes a visual distraction at high session-list density. I'd lean toward Option B (no change) for the v1 ship and revisit if user feedback flags 0/N confusion.

### P2-5: partial-state count contrast borderline at Mac density

**File:** `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:1386`

`t.fg3` resolves to `Color(.sRGB, white: 15.0/255, opacity: 0.46)` on light mode (`TahoeTheme.swift:144`). At 10.5pt, the "3/8" count is ~3.8:1 against the pageBg `Color(.sRGB, red: 244/255, green: 246/255, blue: 250/255)` — below WCAG 4.5:1 for body text. The bar carries the information so this is a *non-essential* text element under WCAG, but at 10.5pt it's not a defensible read in dim-screen scenarios.

**Fix** (if you care about the contrast): bump to `t.fg2` (66% opacity) for the count's partial state. The visual subordination still reads — the bar dominates regardless.

```swift
.foregroundStyle(isComplete ? t.accent : t.fg2)  // was t.fg3
```

Caveat: this slightly competes with the subtitle ("running · 2m ago") which is also `t.fg3` — and you don't want the count to leap above the subtitle in the hierarchy. So *this fix is contingent on a designer reviewing the row balance.* If the subtitle reads quietly at 10.5pt + fg3, the count should match. I'd ship as-is and flag for a a11y audit.

### P2-6: 3pt top pad is a touch tight on Mac

**File:** `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:1389`

The 3pt top pad puts the bar's top edge ~3pt below the status row baseline. On a 10.5pt status row (Mac), that compresses to ~2pt of optical air above the bar after typography metrics resolve. Bumping to 4pt would give the bar a clearer "I am a new visual unit" separation from the status row, without meaningfully changing total row height.

**Fix:**
```swift
.padding(.top, 4)  // was 3
```

iOS at 11.5pt has more inherent breathing room and 3pt is fine; leave it. So this is a Mac-only nudge.

---

## Summary

This pass cleanly fixes the three findings from pass 2 (reduceMotion, height parity, dual-axis payoff). The bar now matches the Tahoe fleet at 6pt, the typography tracks per-platform subtitle sizes, and the checkmark icon transforms 100% from a single-axis to a dual-axis payoff. Score lifts from 91 to 94. The remaining 6 points sit in *visual polish that the production screenshot makes visible* — the checkmark-halo seam blurs the icon-vs-bar distinction at 100%, the checkmark pop has no entry transition while the bar smoothly animates, the count uses `t.accent` (user theme) rather than provider-tinted color at 100% which creates a three-hue clash on Codex/non-Claude sessions, the 0/N just-approved state has no chromatic signal, and the partial-state count at 10.5pt fg3 sits below WCAG body-text contrast in light mode. None are P0 or P1. To reach 98+, address P2-1 (checkmark padding), P2-2 (animated milestone), and P2-3 (provider-consistent count color).
