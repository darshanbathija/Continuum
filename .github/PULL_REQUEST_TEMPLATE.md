## Summary

<!-- 1-3 bullet points on what changed and why. -->

## Test plan

- [ ] `swift test` passes in `apple/ClawdmeterShared`
- [ ] Mac app builds clean: `xcodebuild -scheme "Clawdmeter (Mac)" build`
- [ ] iOS app builds clean (if touched)
- [ ] Watch app builds clean (if touched)

## Manual Apple gate (required for UI / pairing / runtime changes)

Container CI cannot validate the full Apple app surfaces. For any PR that
touches UI, pairing, daemon routes, terminal/session runtime, or packaging,
sign off on the relevant local device/simulator before merge:

- [ ] **macOS:** menu-bar gauge and main window open cleanly
- [ ] **macOS:** Chat, Code, Usage, and Settings load without regressions
- [ ] **macOS:** terminal/session surfaces work if Sessions changed
- [ ] **iOS Simulator/device:** pairing or companion surfaces work if touched
- [ ] **watchOS Simulator/device:** watch surfaces work if touched

If your change is backend-only (daemon route logic / analytics / parsers /
build scripts that don't affect runtime), note "Manual Apple gate: N/A — backend-only".

## Reviewer checklist

- [ ] Self-review: code reads cleanly with no leftover TODOs / dead branches
- [ ] Tests cover new logic (or note why unit-testable doesn't apply)
- [ ] Linked design doc / plan if non-trivial change
