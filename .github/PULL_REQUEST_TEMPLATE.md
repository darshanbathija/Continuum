## Summary

<!-- 1-3 bullet points on what changed and why. -->

## Test plan

- [ ] `swift test` passes in `apple/ClawdmeterShared`
- [ ] `swift test` passes in `linux/` (run on Ubuntu 24.04 or in CI)
- [ ] Mac app builds clean: `xcodebuild -scheme "Clawdmeter (Mac)" build`
- [ ] iOS app builds clean (if touched)

## Manual VM gate (required for any UI / tray / packaging change)

**Codex C10 / D11**: container CI cannot validate GUI surfaces. For any
PR that touches `linux/Sources/ClawdmeterLinux/UI/`, `linux/Sources/ClawdmeterLinux/Tray/`,
`tools/build-linux-*.sh`, or `linux/resources/`, sign off on these on a
real VM before merge:

- [ ] **Ubuntu 24.04 stock VM:** tray icon shows live "Cl X%" label
- [ ] **Ubuntu 24.04 stock VM:** dashboard opens from tray menu
- [ ] **Ubuntu 24.04 stock VM:** SNI dialog appears (extension uninstalled scenario)
- [ ] **Ubuntu 24.04 stock VM:** Secret Service unlock prompt works
- [ ] **Ubuntu 24.04 stock VM:** WebKit web process renders a page (if in-app browser changed)
- [ ] **Ubuntu 24.04 stock VM:** VTE shows live tmux output (if Sessions changed)
- [ ] **Ubuntu 24.04 stock VM:** QR scannable from iPhone (if pairing changed)
- [ ] **ZorinOS 17 VM:** same as above (or "N/A — backend-only change")

If your change is backend-only (daemon route logic / analytics / parsers /
build scripts that don't affect runtime), note "Manual VM gate: N/A — backend-only".

## Reviewer checklist

- [ ] Self-review: code reads cleanly with no leftover TODOs / dead branches
- [ ] Tests cover new logic (or note why unit-testable doesn't apply)
- [ ] Linked design doc / plan if non-trivial change
