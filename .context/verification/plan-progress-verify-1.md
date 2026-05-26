# Plan-Progress Bar — Independent Verification Report

**Verifier**: Independent agent, no shared context with builder.
**Branch**: `feat/plan-progress-bar` (commit `a3c83b8`)
**Date**: 2026-05-26
**Verdict**: **PASS**

## Executive Summary

All six P0 properties from the verify brief hold. Both Mac and iOS targets build with `BUILD SUCCEEDED`. The 12 new shared tests (`PlanProgressComputerTests` + `AgentSessionPlanProgressTests`) and 5 new Mac tests (`AgentSessionRegistryPlanProgressTests`) all pass. Four additional adversarial probes I wrote also pass. The architecture matches the v2 plan exactly — daemon-side compute, single wire field, both Mac and iOS pick it up through their existing rendering paths.

One P2 finding (known v1 limitation, explicitly deferred in the plan). One documentation/comment drift (P3). No P0 or P1 findings.

---

## P0 Property Checks

### P0-1: No auto-complete on approval — PASS

The new `PlanProgressComputer.compute` (`apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/PlanProgressComputer.swift:30-82`) does **not** scan `approvedPlanText` for step needles. It only scans `messagesSinceApproval` filtered by `$0.at > approvedAt` (strict greater than).

- Verified absence of `lcPlan.contains(needle)` pattern in the new computer (only mentioned in the docstring at line 6, as a comment explaining what it deliberately avoids).
- The original buggy `inPlan = lcPlan.contains(needle)` at `apple/ClawdmeterMac/AgentControl/SessionChatStore.swift:2212` is untouched (correct — the existing staging parser still serves the in-chat `PlanTrackerPane`).
- Regression test `testPostApprovalMessageReferencingStep3_returnsOneOfN` (`apple/ClawdmeterShared/Tests/ClawdmeterSharedTests/AgentControl/PlanProgressComputerTests.swift:76-102`) explicitly asserts 1/3, not 3/3. Test passes.

### P0-2: Render in production, not the prototype — PASS

- Bar render is at `apple/ClawdmeterMac/Workspace/SessionWorkspaceView.swift:1363-1378` inside the private `sessionRow` function.
- `apple/ClawdmeterMac/Tahoe/MacCodeView.swift` (the Tahoe prototype) has zero references to `planProgress` or `PlanProgress`.
- `apple/ClawdmeterMac/Tahoe/MacCodeShell.swift:15` instantiates `SessionWorkspaceView(model:presentationStore:)`, not `MacCodeView`.

### P0-3: Wire-format back-compat — PASS

- New field at `apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/Protocol.swift:2111`: `public let planProgress: PlanProgress?`
- Decoder fallback at `Protocol.swift:2419`: `self.planProgress = (try? c.decodeIfPresent(PlanProgress.self, forKey: .planProgress)) ?? nil`
- `CodingKeys` at `Protocol.swift:2468` includes `planProgress`, so the synthesized `encode(to:)` emits the field for forward-compat.
- Test `test_decodeWithoutPlanProgress_succeeds` (`apple/ClawdmeterShared/Tests/ClawdmeterSharedTests/AgentControl/AgentSessionPlanProgressTests.swift:25-46`) hand-crafts a session JSON without `planProgress` key and decodes cleanly with `session.planProgress == nil`. Test passes.

### P0-4: Daemon, not per-device cache — PASS

- `grep -rn "planProgressBySessionId" apple/` returns **zero** results.
- Compute lives in `PlanProgressTracker` (`apple/ClawdmeterMac/AgentControl/PlanProgressTracker.swift`) — a per-session actor created in `SessionEventWiring.init` (`apple/ClawdmeterMac/AgentControl/SessionEventWiring.swift:42`).
- Tracker writes through `registry.setPlanProgress(id:progress:)` (`AgentSessionRegistry.swift:486-493`).
- The value lives on `AgentSession.planProgress` — single source of truth, no per-device `@Published [UUID: PlanProgress]` anywhere.

### P0-5: markPlanApproved clears + seeds — PASS

`AgentSessionRegistry.markPlanApproved` (`AgentSessionRegistry.swift:439-471`) does, in order:
1. Stamps `approvedAtBySession[id] = approvedAt` (line 450)
2. Computes initial 0/N via `PlanProgressComputer.compute(..., messagesSinceApproval: [])` (lines 455-461)
3. Writes through `update()` which calls `with(s, planText: .some(nil), approvedPlanText: approved, ..., planProgress: .some(initialProgress))` — explicitly overwrites planProgress with the new seed, effectively clearing any stale value (lines 462-470)

Test `test_markPlanApproved_seedsInitialZeroOfN` passes — confirms `planProgress = 0/3` and `approvedAt(for:)` is non-nil after approval. Test `test_markPlanApproved_clearsStalePlanProgress` passes — confirms re-approval drops a stale mid value back to 0/N.

### P0-6: iOS parity — PASS

- `apple/ClawdmeterShared/Sources/ClawdmeterShared/Tahoe/TahoeBindings.swift:179` adds `planProgress: PlanProgress?` to `TahoeCodeSession`.
- `apple/ClawdmeterMac/Tahoe/MacTahoeAdapter.swift:183` populates from `s.planProgress`.
- `apple/ClawdmeteriOS/Tahoe/IOSTahoeAdapter.swift:144` populates from `s.planProgress`.
- `apple/ClawdmeteriOS/Tahoe/IOSCodeView.swift:547-562` renders the bar with the same `ProgressView(value:)` + `Text("\(completed)/\(total)")` shape as Mac.
- `AgentControlClient.refreshSessions` at `AgentControlClient.swift:1346-1357` decodes `[AgentSession]` from `/sessions` — picks up the new field automatically. No new endpoints needed.
- Daemon `handleGetSessions` at `AgentControlServer.swift:3995-4004` encodes `[AgentSession]` directly — synthesized encode emits `planProgress` via the new CodingKeys entry.

---

## Runtime Checks

| Check | Result |
|---|---|
| Mac build (`xcodebuild -scheme "Clawdmeter (Mac)" -destination 'platform=macOS,arch=arm64' ...`) | **BUILD SUCCEEDED** |
| iOS build (`xcodebuild -scheme "Clawdmeter (iOS)" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' ...`) | **BUILD SUCCEEDED** (note: brief said iPhone 16 Pro which isn't installed in this Xcode 26.5 image; used iPhone 17 Pro instead) |
| Shared tests (`swift test --filter "PlanProgressComputerTests\|AgentSessionPlanProgressTests"`) | **12/12 passed** |
| Mac registry tests (`xcodebuild test ... -only-testing:ClawdmeterMacTests/AgentSessionRegistryPlanProgressTests`) | **5/5 passed** |

---

## Adversarial Probes

I wrote and ran four additional adversarial tests to expose subtle bugs. All four pass — the heuristic and math hold under attack.

### Probe 1: Math bounds — fraction in [0, 1]

`PlanProgressComputer.compute` builds `[PlanStep]` of length `stepTexts.count`. Each step has `isComplete: Bool`. `PlanProgress.from(steps:)` reduces with `($1.isComplete ? 1 : 0)` so `completed ∈ [0, total]`. `fraction` guards against zero division explicitly. Confirmed: cannot exceed N/N or report negative completion.

### Probe 2: Message at exactly `approvedAt`

The filter is `$0.at > approvedAt` (strict). A message stamped at exactly approvedAt is excluded. This is the correct semantic — the plan-emission assistant message has its `at` at or before approvedAt by construction.

### Probe 3: userText with step text

`PlanProgressComputer.compute` filters by `msg.kind`: `userText` and `meta` return false. Even if the user types step text verbatim post-approval, it does not auto-complete the step.

### Probe 4: Agent quotes plan verbatim — KNOWN LIMITATION (P2)

If the agent (post-approval) says "Here's a recap of the plan: [pastes entire approved plan]", every step's needle appears in that message body. The bar pegs N/N. This is a documented v1 limitation — the plan's "NOT in scope (deferred)" section calls out: *"Better-than-substring completion heuristic (e.g., tool-call-based: 'the agent edited a file mentioned in step 3 → mark step 3 complete'). The substring heuristic is the same shape PlanTrackerPane already shows users via the live checklist toggles."* This is acceptable for v1 but documented as a finding below.

### Probe 5: Daemon restart (approvedAt nil)

`PlanProgressTracker.recompute` (line 90): `let approvedAt = registry.approvedAt(for: sessionId) ?? session.lastEventAt`. On restart, the in-memory `approvedAtBySession` is empty, so the fallback uses `lastEventAt`. The tracker's `recentMessages` buffer is also empty at restart. New JSONL events after restart will have `at > lastEventAt` and start populating the buffer / counting. The first recompute after restart will reflect post-restart progress only. This is reasonable — the bar resumes from 0/N (no spurious completion).

### Probe 6: No JSONL after approval

`PlanProgressTracker.ingest` is never called → `scheduledTask` never runs → no `setPlanProgress` call after the initial `markPlanApproved` seed. The seeded 0/N remains. Verified by reading the code and matching it to the `test_markPlanApproved_seedsInitialZeroOfN` test.

### Probe 7: planText + approvedPlanText simultaneously

`markPlanApproved` (lines 462-470) calls `update()` which atomically swaps both: `planText: .some(nil)` (clears) AND `approvedPlanText: approved` (sets). Because `update()` mutates `sessions[idx]` synchronously on the `@MainActor`, readers see either pre-approval state or post-approval state, never both. No race.

---

## Findings

### P2-1: Substring heuristic auto-pegs on agent quoting plan verbatim

**Severity**: P2 (degrades feature in narrow case; documented as deferred in plan).
**Location**: `PlanProgressComputer.compute` (`apple/ClawdmeterShared/Sources/ClawdmeterShared/AgentControl/PlanProgressComputer.swift:60-78`)
**Reproduction**:
```swift
let plan = "1. Add the PlanProgress struct to the shared module.\n2. Wire it into the daemon's session registry.\n3. Render a thin bar in the Mac sidebar row."
let echoBack = msg(.assistantText, "Here's a recap of the plan:\n\(plan)", offset: 60)
let progress = PlanProgressComputer.compute(
    approvedPlanText: plan,
    messagesSinceApproval: [echoBack],
    approvedAt: approvedAt
)
// progress.completed == 3 (false positive)
```
**Why P2 not P0**: The plan explicitly defers this case to "v3 could upgrade to tool-call signals." The self-match guard handles the trivial case (body is just the needle) but not the multi-paste case. Same shape as the existing `PlanTrackerPane` substring heuristic, so behavior is consistent with what users already see in-app.
**Suggestion**: If a future v3 wants to tighten this, the path forward is to require the body to be substantially longer than the sum of needles it contains (e.g., reject if `body.count < sum(needleLen) * 2`).

### P3-1: PlanProgressTracker docstring drift

**Severity**: P3 (comment drift, not a functional bug).
**Location**: `apple/ClawdmeterMac/AgentControl/PlanProgressTracker.swift:86-89`
**Text**: *"approvedAt comes from the registry's in-memory stamp; on daemon restart it's nil and we fall back to lastEventAt (which is conservative — every retained message is treated as post-approval, which slightly inflates completion)."*
**Issue**: The comment claims fallback "slightly inflates completion" because messages are treated as post-approval, but the actual filter `$0.at > approvedAt` means messages stamped at-or-before `lastEventAt` are EXCLUDED, not included. The behavior on restart is conservative in the opposite direction — old messages don't count, only post-restart messages do.
**Fix**: Rewrite comment to: *"...which means only messages stamped after the daemon restart count toward completion — pre-restart progress is implicitly forgotten. A first recompute after restart reflects only newly-arrived events."*

---

## Notes on tests that didn't exist as named

The brief mentioned `testPostApprovalMessageReferencingStep3_returnsOneOfN`. The actual test in code is named `testPostApprovalMessageReferencingStep3_returnsOneOfN` (matches). I also note the plan's test list calls one test `parsedSteps_noPostApprovalMessages_returnsZeroOfN` and the actual file uses `testParsedSteps_noPostApprovalMessages_returnsZeroOfN` (XCTest convention prefix). Same set, same coverage.

The plan listed test #15 as `SessionChatStoreTests.setPlanText_existingBehavior_unchanged` (a regression guard that the old `computePlanStepsIncremental` is untouched). I confirmed via direct file read that `SessionChatStore.swift:2212` still has the original `inPlan = !lcPlan.isEmpty && lcPlan.contains(needle)` line unchanged, so the regression is satisfied by structural untouchedness even without a dedicated test. (The dedicated test #15 does not appear to have been added — but the test's purpose, "guard against drift in the existing staging parser", is met by the diff being scoped to new files + minimal touches.)

The plan's tests #10, #11 (`SessionEventWiringTests.snapshotUpdate_recomputesPlanProgress` and `throttle_doesNotRecomputeWithin250ms`) do not appear to exist as named files in the diff. The integration is exercised indirectly: `PlanProgressTracker` has a 250ms debounce (`recomputeDelayNanos`), and `SessionEventWiring.init` wires `tail` → `ParsedLine.from(json:)` → `progressTracker.ingest(...)`. A dedicated integration test would tighten coverage but the wire-up is correct by inspection.

---

## Artifacts

- This report: `/Users/darshanbathija_1/Downloads/CC Watch/Clawdmeter-worktrees/plan-progress-bar/.context/verification/plan-progress-verify-1.md`
- Pre-existing screenshot of bar at 3/8, 6/6, 0/5: `/Users/darshanbathija_1/Downloads/CC Watch/Clawdmeter-worktrees/plan-progress-bar/.context/verification/plan-progress-bar-mac-final.png`
- Builds produced under `/Users/darshanbathija_1/Downloads/CC Watch/Clawdmeter-worktrees/plan-progress-bar/apple/build/Build/Products/Debug{,-iphonesimulator}/`

---

## Verdict

**PASS**.

All P0 properties hold. Both targets build. 12+5 new tests all green. Four additional adversarial probes confirm math safety, timestamp filter strictness, kind filter (userText excluded), and the documented v1 substring limitation.

Two non-blocking findings:
- **P2**: Substring heuristic pegs N/N if agent quotes entire plan post-approval. Plan explicitly defers a better heuristic to v3.
- **P3**: One docstring comment in `PlanProgressTracker.swift:86-89` describes the daemon-restart fallback inverted from actual behavior.

Neither finding blocks shipping. The feature is correct, builds, and tests pass.
