# Continuum — Known Limitations

This doc enumerates work that is described in the plan or implied by
the security / privacy posture, but is still deferred or follow-up. Companion
docs are [`docs/security.md`](security.md) and
[`docs/privacy.md`](privacy.md); both cite this file in their
"status note" callouts.

Plan reference: `~/.claude/plans/study-this-codebase-crystalline-shore.md` (maintainer-local; not checked in).

---

## 1. Secure relay + APNS is live, with hardening follow-ups

The secure-cloud pairing path now has both Worker and Apple-client pieces:

- **E2 — relay Worker** at `infra/relay/`.
  [PR #151](https://github.com/darshanbathija/Clawdmeter/pull/151).
- **E5 — APNS gateway Worker** at `infra/apns-gateway/`.
  [PR #147](https://github.com/darshanbathija/Clawdmeter/pull/147).
- **Mac relay client** at
  `apple/ClawdmeterMac/AgentControl/RelayClient.swift` plus
  `RelaySubscriptionBridge.swift`.
- **iOS relay client** at
  `apple/ClawdmeteriOS/AgentControl/IOSRelayClient.swift` and
  `IOSRelayClientCoordinator.swift`.
- **Relay mux/shared transport** under
  `apple/ClawdmeterShared/Sources/ClawdmeterShared/Relay/`.
- **APNS client/registration** at
  `apple/ClawdmeterMac/AgentControl/APNSGatewayClient.swift` and
  `apple/ClawdmeteriOS/iOSAPNSRegistration.swift`.

What remains follow-up:

- **Operational drills.** Rotation, kill-switch, canary, and incident
  drills need regular production proof after the live relay/default
  transport cutover.
- **Relay edge hardening.** Keep tightening rate limits, replay windows,
  signed creation grants, and auth telemetry as production traffic grows.
- **APNS delivery polish.** Keep validating token cleanup, retry behavior,
  and degraded-mode user copy under real device churn.

**Net effect:** Mac and iPhone clients can use the relay/APNS Worker path.
Loopback/Tailscale remains useful for local development and fallback:

- Pairing remains QR/token based.
- Relay transport avoids requiring both devices to share a LAN or
  Tailscale route.
- APNS is the low-latency path for plan-approval notifications when
  the device token and gateway are available.

## 2. Relay crypto parity is guarded by vectors

The relay wire protocol uses **XChaCha20-Poly1305** with a 24-byte nonce
(per the design doc §4.3 and the test vectors at
`infra/relay/test-vectors/xchacha20-poly1305-001.json`). The TypeScript
Worker uses `libsodium-wrappers-sumo`; Apple clients use CryptoKit plus
Continuum's pure-Swift HChaCha20 prelude to derive the 12-byte
`ChaChaPoly` nonce form.

This is no longer a product blocker. Keep the shared test vectors as the
contract whenever relay crypto changes.

## 3. F3 HOME isolation type carrier shipped; daemon wire-up deferred

`ProviderInstanceId` and `ProviderInstanceRegistry`
([PR #142](https://github.com/darshanbathija/Clawdmeter/pull/142))
land the type-level seam for per-provider HOME isolation. The value
type carries:

- `homePathOverride: String?` for per-instance config isolation.
- `keychainAccessGroupOverride: String?` for per-instance Keychain
  partitioning.

The PR is source-only. What is NOT yet shipped (deferred to F3-wire):

- `AppRuntime` does not yet split `AppModel` instances per
  `ProviderInstanceId`. There is still one `AppModel` per
  `AgentKind`.
- The daemon wire bump (`providerInstanceId` field on the mobile
  protocol gated to `wireVersion ≥ 21`) is not in main.
- The Codex #10 security invariants — Keychain partitioning
  enforcement, env scrubbing on child spawn, credential-bleed
  integration tests, per-instance log redaction — are typed into the
  value but the daemon does not enforce them yet.

**Net effect:** `claude_personal` and `claude_work` cannot be
configured side-by-side today. The primary instance for each kind is
the only one with a code path. F3-wire is the next planned PR in the
backend architecture track.

## 4. C2 `@Observable` migration deferred

The marketing posture and several performance characteristics
described in the GTM document assume post-C2 state — the
`@Observable` macro migration of `UsageHistoryStore` and
`SessionChatStore`. That PR is not in main.

What IS in main from Track 1 (perf):

- A4 — `MemoizedDerivedStore` shared utility for chart + sidebar
  derived properties ([PR #139](https://github.com/darshanbathija/Clawdmeter/pull/139)).
- A5 — `SessionChatStore` slice publishing into per-concern stores
  ([PR #153](https://github.com/darshanbathija/Clawdmeter/pull/153)).
- A6 (foundation) — 12-subview extraction from
  `SessionWorkspaceView.swift` plus `BodyInvalidationCounter`
  ([PR #149](https://github.com/darshanbathija/Clawdmeter/pull/149)).
- A11 — sidebar projection cache
  ([PR #148](https://github.com/darshanbathija/Clawdmeter/pull/148)).
- A12 — diff workbench off-main parse + cache + virtualized rows
  ([PR #145](https://github.com/darshanbathija/Clawdmeter/pull/145)).
- A13 — composer optimistic UI
  ([PR #150](https://github.com/darshanbathija/Clawdmeter/pull/150)).
- B1 — `IncrementalJSONLIngest` actor
  ([PR #144](https://github.com/darshanbathija/Clawdmeter/pull/144)).
- C1 — chart + repo-list compute off-main
  ([PR #140](https://github.com/darshanbathija/Clawdmeter/pull/140)).

What is NOT in main: the C2 macro migration itself. Body
invalidation drops attributed to "post-C2" in marketing should be
treated as the target shape, not the current shape.

## 5. watchOS Tahoe-debt

The watchOS app surfaces still use raw `.secondary` colors instead of
the `TahoeTokens.secondary*` palette, do not invoke `TahoeFont.rounded`
for typographic affordances, and do not apply `.tahoeTheme(store)` at
the app root. This is design debt flagged for a separate polish PR.

A planned watch-side ship will:

1. Replace raw `.secondary` calls with the `TahoeTokens` palette so
   color reads consistently across surfaces.
2. Adopt `TahoeFont.rounded` for headings + numeric callouts.
3. Apply `.tahoeTheme(store)` at the app root so theme toggles
   propagate.

Tracked separately. Not blocking Gate 0.

## 6. iOS launch surface Tahoe-debt

The iOS app's launch surface received a 62/100 score from the design
critique pass — short of the 98 floor the verify loop calls for. The
shortfall is concentrated in the launch view (pairing-state surface,
initial empty state, first-paint hierarchy) and is flagged for a
separate polish PR.

Concretely:

- The pairing-state empty view doesn't use the same `TahoeGlass` +
  `prominent` opt-in pattern as the Mac.
- First-paint typography mixes `.headline` and raw `Text(.largeTitle)`
  without the rounded `TahoeFont` numeric variant the Mac uses.
- The "no paired Mac" CTA has unclear hierarchy — the Pair button
  competes visually with the "Set up Tailscale" link.

The iOS workbench (post-pair) is in better shape; this is specifically
the cold-start / unpaired surface.

Tracked separately. Not blocking Gate 0.

## 7. Mac Code-tab pre-existing density issues

The Mac Code tab has pre-existing density issues that were noted but
deferred from the A6 workspace split
([PR #149](https://github.com/darshanbathija/Clawdmeter/pull/149)):

- **Sidebar truncation.** Long session titles truncate without an
  affordance for the full text on hover.
- **Composer rhythm.** Spacing between the composer input, the
  attachment chips, and the send button does not follow the Tahoe
  8/12/16 rhythm consistently.

These are density / polish issues, not correctness issues. The A6
foundation PR explicitly preserved the existing visual layout while
extracting 12 sub-views; a follow-up polish PR can tighten the rhythm
without regressing the invalidation drop A6 delivered.

Tracked separately. Not blocking Gate 0.

## 8. Sparkle follow-ups

Sparkle full-update archives ship first. Two follow-ups remain outside
the initial PR:

- Delta updates after at least two full Sparkle archives exist.
- Sparkle key-rotation drill after the first production appcast has
  been exercised.

These are release-operations drills, not runtime blockers.

## 9. Updates to this document

When an item listed here ships, the corresponding section should be
deleted (not crossed out) in the PR that ships it, and the doc should
be updated as part of the same PR. The git history of this file is
the audit trail.
