# QA Report — Clawdmeter `bugfix/audit-fixes-v2`
Date: 2026-05-20
Mode: diff-aware (native Apple app — adapted from web-browse default)
Branch: bugfix/audit-fixes-v2 (38 commits ahead of origin/main)
Base: origin/main

## Summary

| Metric | Result |
|---|---|
| swift test | **457/457 passing** |
| ClawdmeterMac (xcodebuild) | ✅ BUILD SUCCEEDED (after 1 fix) |
| ClawdmeteriOS (xcodebuild) | ✅ BUILD SUCCEEDED |
| ClawdmeterWatch (xcodebuild) | ✅ BUILD SUCCEEDED |
| Issues found | 1 (Critical) |
| Issues fixed | 1 (verified by re-build) |
| Issues deferred | 0 |
| Health score | 100/100 (post-fix) |

**PR Summary:** QA found 1 critical issue, fixed it, build matrix now green.

## Issue Inventory

### ISSUE-001 (Critical — build break) ✅ Fixed: `a0805cd`

**Title:** `SessionsView.humanize` switch over `TmuxControlClient.TmuxError` non-exhaustive

**Location:** `apple/ClawdmeterMac/SessionsView.swift:151-158`

**Root cause:** `TmuxControlClient.TmuxError` enum (defined at `apple/ClawdmeterMac/AgentControl/TmuxControlClient.swift:477-483`) has 5 cases: `notStarted`, `commandFailed(String)`, `serverExited`, `ptyClosed`, **`invalidArgument(String)`**. The switch in `SessionsView.humanize` only covered 4. Swift's `error: switch must be exhaustive` prevented the Mac build from compiling.

**Repro steps:**
1. `cd apple && xcodebuild -scheme "Clawdmeter (Mac)" build`
2. Build fails with: `SessionsView.swift:152:9: error: switch must be exhaustive`

**Evidence:** `xcodebuild` stderr captured in `/private/tmp/claude-502/.../bc3d08f5e.output`.

**Fix:** Added the missing case to `humanize`:
```swift
case .invalidArgument(let s): return "tmux: invalid argument (\(s))"
```

**Verification:** Re-built `Clawdmeter (Mac)` → `** BUILD SUCCEEDED **`. iOS + Watch already green.

**Regression test:** Skipped per /qa Phase 8e.5 spirit — the Swift compiler's exhaustiveness check IS the regression test. A unit test asserting "TmuxError has these N cases" would just duplicate compiler behavior; if the case is ever removed, the build breaks immediately at the same site.

**Files changed:** 1 (`apple/ClawdmeterMac/SessionsView.swift`, +1 line)

## Branch-wide observations

The 38 commits on this branch are audit-track fixes spanning Mac (8 files), iOS (6 files), Shared (14 files), Watch (1 file), and Linux (5+ files). Notable patterns:

- **Codex-N series** (codex-1 through codex-9): Latest audit pass — focused on artifact-path safety (`..` rejection, allowlist), background-task lifecycle (single-shot guards, cancellable sleeps), token-cache invariants (unconditional clear on empty setToken), and Linux daemon hardening (fail-loud, runtimeDir mode, IPv6 rollback).
- **P1/P2 series**: Earlier audit pass — covered `GeminiTokenProvider.refreshIfNeeded` (throws on expired), ShellRunner termination handler (vs 50ms poll), and SwiftUI cross-platform guards via `#if canImport(SwiftUI)`.

All 457 unit tests pass against these changes — including the `GeminiProviderLaneATests`, `ProviderHardcodingAuditTests`, `WireV8Tests`, and `WatchPlanBridgePayloadTests` that gate the cross-version compat surfaces.

## Cross-branch context

The broken `feat/codex-sdk-v073-final` work flagged by today's /review session is **unrelated** to this branch. `bugfix/audit-fixes-v2` was cut earlier and never received the broken v0.7.3 changes. Recommend merging this audit branch into `main` (after one more reviewer pass) without touching the v0.7.3 attempt.

## Health Score: 100/100 (post-fix)

| Category | Score |
|---|---|
| Build (Mac/iOS/Watch) | 100/100 |
| Tests (swift test) | 100/100 |
| Console errors | n/a (native app) |
| Type-system soundness | 100/100 (was 0; exhaustiveness fix locked in) |
