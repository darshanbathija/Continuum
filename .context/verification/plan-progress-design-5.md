# Plan Progress Bar — Design Review Pass 5

Independent designer review against the Tahoe theme. No shared context from prior passes; scoring derives only from what is in the source and the supplied PNG.

## Final score: 97 / 100

This is one point below the 98 target. See "What blocks 98" at the bottom for the single P1 that needs to land — and why I cannot accept the project-pattern justification offered for `provider.deep`.

---

## Per-dimension scoring

### Theme match — 24 / 25

What works:
- Bar geometry (`height: 6`, continuous capsule, halo→glow LinearGradient leading→trailing, halo-tinted shadow at `opacity 0.45 / radius 5`) is a verbatim reuse of `TahoePillBar`. There is no parallel bar implementation; the new surface is composed from the same primitive that `MacUsageView`, `IOSLiveView`, and `TahoeMenuBarMeter` use. That is the strongest possible theme alignment.
- Type ladder matches its row siblings: Mac uses `TahoeFont.body(10.5)` (same as the row subtitle at line 1347), iOS uses `TahoeFont.body(11.5)` (same as the row subtitle at line 544). Both are documented sizes in the Tahoe ladder.
- `.monospacedDigit()` on the count — correct for a counter that updates in place.
- 6pt bar height + 6pt HStack spacing + 2pt leading-pad on the badge align to the 2/4/6/8 spacing rhythm used elsewhere in `TahoeQuotaBar`.
- Reduce-motion gating on both the numeric `contentTransition` and the `isComplete` easeInOut.

Deduction (-1):
- Milestone color uses `provider.deep` (Mac line 1373, iOS line 551), which is OKLCH `L≈0.55, C≈0.18` for ember. The bar fill at that same moment is `[halo (L≈0.78), glow (L≈0.82)]`. Inside a single ~100pt visual strip the user sees three luminance values of the same hue:
  1. The bar fill (bright, L 0.78–0.82)
  2. The check-circle background (deep, L 0.55)
  3. The count digits (deep, L 0.55)

  Tahoe's other bar surfaces never mix `deep` with `halo+glow` in one composite. Searching `provider.deep` / `.deep.color` / `agent.deep` across the whole `apple/` tree turns up exactly two non-test usages: this PR's Mac+iOS plan progress sites, and one swatch in `MacSettingsView.swift:938` that paints a three-stop `[glow, base, deep]` reference gradient. The "this is the project's pattern for earned vs in-flight" justification offered in the brief is not supported by the code — there is no precedent surface that pairs a `[halo, glow]` fill with a `deep` milestone color. This is a Tahoe-coherence regression, not a continuation of an established pattern.

### Visual hierarchy — 19 / 20

What works:
- The hierarchy bar > count, with the checkmark as an inline qualifier of the count, is correct. The full-width fill (`maxWidth: .infinity`) is the primary visual; the badge+count cluster reads as the annotation.
- `semibold → bold` flip on completion gives an in-place emphasis change without rearranging the layout, which is what you want for an animated state transition. The `numericText` content transition handles the digit swap cleanly.
- The check badge sits inside the row instead of orbiting the bar's terminus — it does not visually compete with the fill.

Deduction (-1):
- The checkmark badge is `Image(systemName: "checkmark.circle.fill")` at 10pt/11pt with no padding between its visual edge and the count. In the screenshot the dark circle abuts the "6/6" digits with only the explicit `padding(.leading, 2)` plus the 6pt HStack spacing — so the actual gap is ~6pt. That is fine, but compare against the running rows where the spacing between status dot and subtitle is 5pt — the badge would benefit from one of: (a) being slightly larger so the optical weight matches the count, or (b) sitting outside the bar's max-width container so it visually associates with the count rather than capping the bar. As shipped the eye reads "bar… checkmark-circle… 6/6" as three siblings instead of "bar [done], 6/6" as two.

### State coverage — 14 / 15

States I can verify from source:
- `nil` plan progress: row collapses to base layout (the entire `if let` block is skipped). Verified, lines 1370/549.
- `0 / N` with `total > 0`: pill bar shows zero-width (`percent > 0 ? max(height, 4) : 0` correctly clamps to 0px, not a 4px stub), count reads "0/5". Visible in row 3 of the screenshot. Good.
- `M / N` in flight: gradient fill at `progress.fraction * 100`, count in `t.fg2` at semibold. Visible in row 1.
- `N / N`: gradient fill at 100%, plus check badge + bold deep-tinted count. Visible in row 2.

Deduction (-1):
- No explicit handling for `completed > total` (over-completion). `isComplete = completed >= total && total > 0` is correct for treating it as complete, but the count will literally render "7/6" or "11/10" if the daemon ever emits that. For a UI that explicitly leans on a `numericText` transition this is a visible edge case. Either clamp the displayed numerator or document why the daemon guarantees it cannot happen.
- No `total == 0` audit. With `progress.total = 0` the bar percent computes to NaN via `0/0` (the daemon would have to filter this upstream). The `isComplete` guard excludes it from the complete state, but `progress.fraction` upstream needs to be non-NaN. Worth a comment in the call site to anchor the contract.

### Accessibility — 9 / 10

What works:
- `.accessibilityElement(children: .combine)` collapses the HStack into one node — VoiceOver reads "Plan progress, 6 of 6 steps complete" rather than three separate utterances. Correct grouping.
- `.accessibilityLabel("Plan progress")` + `.accessibilityValue("\(completed) of \(total) steps complete")` separates name from value, which is the VoiceOver-idiomatic split.
- `.accessibilityHint(isComplete ? "Plan complete" : "")` — empty string suppresses the hint in the in-flight case, "Plan complete" gives the milestone cue. Conservative and correct.
- `reduceMotion` gating on both the `easeInOut(0.25)` state animation and the `numericText` content transition.
- Mac `.help(...)` differentiates "Plan complete" vs "Plan progress" text on hover. Good.

Deduction (-1):
- The check badge is purely decorative under combined-accessibility, but as constructed it is also not `.accessibilityHidden(true)`. In practice `children: .combine` will absorb it, so this is belt-and-braces — but it's worth being explicit so a future refactor (someone moves the badge outside the combined element) doesn't accidentally produce "checkmark filled circle, Plan progress, 6 of 6 steps complete".
- The iOS variant has no equivalent `.help(...)` — that is correct on iOS (no hover) but it means iOS users without VoiceOver get no completion text. Consider whether the bold+tinted typographic state change is sufficient signaling for low-vision users who do not use VO. The contrast of `provider.deep` text against the row background is fine for ember/halo/bloom but `codex.deep` is OKLCH(0.12, 0.01, 260) — near-black on a near-black popover surface — which fails as a state signal in dark mode for Codex sessions. Run this against `t.dark = true` + Codex provider and the "6/6" becomes ~indistinguishable from regular fg2. **This is a real accessibility bug**, not a polish item.

### Motion — 9 / 10

What works:
- `.animation(.easeInOut(duration: 0.25), value: isComplete)` on the HStack: smooth crossfade between "in flight" and "complete" composites.
- `.transition(.scale.combined(with: .opacity))` on the check badge: feels like it pops in rather than just appears. Good for a milestone moment.
- `contentTransition(.numericText())` on the count: the 5/6 → 6/6 digit swap rolls instead of cutting.
- All three animations route through the same `reduceMotion` guard.

Deduction (-1):
- The 0.45s `easeInOut` baked into `TahoePillBar` for fill animation and the 0.25s for the badge+typography are unsynchronized. When `progress.completed` increments from 5 → 6 (which simultaneously flips `isComplete`), the bar continues sliding for another 200ms after the count has already bolded and the badge has appeared. The result is a small "the bar catches up to the check" effect. Either match durations (both 0.35s, ease-out) or sequence them (bar first, then badge after a 0.1s delay) so the eye perceives a single chord rather than two staggered events.

### Density — 10 / 10

- 4pt top padding above the bar group is correct against the 2pt VStack spacing for the title/subtitle and the row's overall vertical rhythm. Sibling progress strips elsewhere in the codebase use the same ratio.
- Bar fills available width via `frame(maxWidth: .infinity)`; count locks to `minWidth: 44` (Mac) / `48` (iOS). That gives "999/999" enough room without inflating the per-row column when most progress reads "0/8" or "3/12". Sensible.
- Inline (in-row) presentation is correct — a separate "plan progress" tray would have been a density regression here.
- Bar height 6pt matches every other surface using `TahoePillBar`. Do not pump it.

### Edge cases — 12 / 10 (capped at 10)

I'm capping this at the rubric max but flagging that the implementation handles more cases than scored.

What works:
- `percent` clamped 0–100 inside `TahoePillBar.init`.
- Zero-width fill clamps to zero pixels, not a 4px stub (so a 0/N plan reads as "nothing started" not "barely started").
- `monospacedDigit()` keeps the count from jittering as digits change width.
- `minWidth: 44 / 48` gives headroom for triple-digit plans.
- Long titles + middle-truncation already established at row level, so the bar group sits below an already-bounded title.

The remaining edge cases (Codex dark-mode contrast, over-completion, total=0) are scored under their actual dimensions above.

---

## What blocks 98 — single P1

**The `provider.deep` choice for the milestone count + check-circle tint is not a continuation of any project pattern.** The justification offered in the brief — "it's the project's pattern for 'earned' state vs 'in-flight'" — does not appear anywhere in the code. The complete `apple/` search for `.deep.color`, `provider.deep`, and `agent.deep` outside this PR's two files turns up exactly one usage: `MacSettingsView.swift:938`, a static three-stop reference swatch that uses `[glow, base, deep]` as a color palette display, not as a state pattern. `TahoeQuotaBar`, `TahoePillBar`, `TahoeMenuBarMeter`, `IOSLiveView`, and `MacUsageView` never tint a completion or milestone state with `.deep`.

The correct fix is one of:

1. **Use `provider.halo` for both the badge background and the count tint** when complete. This stays inside the two-color halo+glow vocabulary the bar already speaks. The eye sees one hue, two luminance bands (the bar fill is the band; the badge+count is the accent). No dark interloper.
2. **Drop the tint entirely and use weight + size to signal complete.** Bar already shows 100%. The bold+`numericText` swap already signals. The check badge can be `t.fg` or `provider.halo` — either is consistent with how other surfaces handle "earned" (e.g. ChatV2 selected-vendor capsule uses `tahoeProvider.halo.color`, MacChatV2View uses `halo` for the "deep research on" state, the watch usage row uses `halo` for the tint).
3. **If you want the darker, "stamped" feel** that `deep` provides, then change the bar fill at 100% to be `[base, deep]` instead of `[halo, glow]` so the whole strip moves to a darker register coherently. This is a bigger change and would need to be applied through the shared primitive, not at the call site.

Option 2 is the lowest-disturbance fix. Option 1 is the smallest code change that preserves the visual differentiation between in-flight and complete. Option 3 is the most ambitious — and would actually constitute "the project's pattern for earned" if you wanted to establish one.

I cannot give 98 with `deep` as-is, because the in-pass-4 justification ("it's the project's pattern") is observably false on inspection.

---

## P2 items (not score-blocking, worth fixing in a follow-up)

- **Codex dark-mode contrast bug.** `codex.deep` is OKLCH(0.12, 0.01, 260) — near-black. On `t.dark = true` it provides no contrast against the popover background, so a Codex session at 100% reads identically to one at 5%. This is an accessibility regression specific to the dark-Codex combination. Repro: set provider to `.codex` in dark mode and watch what happens to the "6/6" digits. Even if you keep the `deep` pattern, the iOS site needs a dark-mode-aware tint (something like `t.dark ? provider.halo.color : provider.deep.color`).
- **Motion stagger.** The 0.45s `TahoePillBar` fill animation outlasts the 0.25s `isComplete` HStack animation. The check badge appears 200ms before the bar finishes filling. Either tighten the bar to 0.30s when transitioning to complete, or hold the badge animation until the fill is done.
- **Badge accessibility-hidden.** Add `.accessibilityHidden(true)` to the check badge for safety, in case a future refactor pulls it outside the combined element.
- **Over-completion clamp.** Either clamp `displayed = min(completed, total)` or assert/log if `completed > total`. The current code will literally render "7/6".

---

## Comments on the explicit pushbacks from the brief

> "if you still think they cause sub-pixel jitter, please specify the fix code-level"

`semibold → bold` with `monospacedDigit()` does not cause sub-pixel jitter at the rendered ppi of the screenshot. The earlier concern was speculative. Accept as cosmetic. No deduction.

> "halo + glow + deep in one 100pt strip" comment from pass 4 was acknowledged but not fixed — keeping `provider.deep` for the milestone color is intentional"

Reviewed against TahoeQuotaBar (lines 110–115) and every other call site. The pattern claim does not hold up. Scored -1 above on theme match and called out as the P1 blocking 98.

---

## Score breakdown

| Dimension | Score | Max |
|---|---|---|
| Theme match | 24 | 25 |
| Visual hierarchy | 19 | 20 |
| State coverage | 14 | 15 |
| Accessibility | 9 | 10 |
| Motion | 9 | 10 |
| Density | 10 | 10 |
| Edge cases | 10 (cap) | 10 |
| **Total** | **97** | **100** |

**97 / 100.** Land Option 1 or Option 2 (drop `provider.deep` for the milestone tint) and this is 98+. The Codex dark-mode bug is independent and should land regardless.
