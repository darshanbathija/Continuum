# Continuum — Privacy

This doc enumerates every byte that leaves the user's Mac. The
companion docs are [`docs/security.md`](security.md) (how the egress
paths are protected) and
[`docs/known-limitations.md`](known-limitations.md) (what isn't shipped
yet).

> Status note. Several egress paths described here are designed but
> not yet live in main: the Cloudflare relay (E2) and APNS gateway
> (E5) Workers are deployed, but the Mac/iOS clients that talk to them
> (E3, E4, E6) are not. The current shipped pairing path is still
> Tailscale-or-local-network. See
> [`docs/known-limitations.md`](known-limitations.md) for the precise
> live-vs-designed table.

---

## 1. What data leaves the user's machine

There are exactly five categories of network egress from a default
Continuum install.

### 1.1 Pairing relay (designed; shipped Worker, client lands in E3/E4)

When the Cloudflare relay path is used (the secure-cloud pairing
mode), the Mac daemon and the paired iPhone exchange opaque
XChaCha20-Poly1305 envelopes through a Cloudflare Worker
(`infra/relay/`). The Worker sees:

- The encrypted envelope bytes (it cannot decrypt them).
- A short header: protocol version, sender role (`mac` or `ios`),
  envelope type (`handshake`, `ciphertext`, or `control`).
- TCP/TLS connection metadata: the source IP, the timing of opens
  and closes, byte counts.
- The session id presented at WebSocket open.

The Worker does NOT see:

- Anything inside the envelope. Chat messages, code diffs, plan text,
  approval decisions — all of it is sealed with a symmetric key the
  Worker does not hold.
- Identifying information about either peer beyond the per-pairing
  bearer-token hashes the Worker stored at session creation.
- Long-lived identifiers. Each pairing generates fresh ephemeral
  keys; nothing persists across pairings.

Source: [PR #151](https://github.com/darshanbathija/Clawdmeter/pull/151).

### 1.2 APNS gateway (designed; shipped Worker, client lands in E6)

When the Mac daemon sends a plan-approval push notification, it goes
through a separate Cloudflare Worker (`infra/apns-gateway/`) that
holds the operator's Apple Developer `.p8` signing key. The gateway
forwards the push to Apple's HTTP/2 APNS endpoint. The gateway sees:

- The SHA-256 hash of the iPhone's APNS device token (the raw token
  reaches the Worker only as the request body; it is hashed before
  any KV write or log line).
- The bundle id (`com.clawdmeter.iphone`, `com.clawdmeter.watch`).
- The APNS topic.
- The byte length of the encrypted payload.
- The SHA-256 fingerprint of the sender Mac daemon's pairing public
  key.
- Push delivery metadata (Apple's response status, the `apns-id` UUID,
  the timestamp).

The gateway does NOT see:

- The decrypted notification body. The body is sealed with the
  per-pairing symmetric key derived during pairing (HKDF
  `info = "clawdmeter.apns.v1"`); only the iPhone can decrypt.
- The raw device token in any persisted form — only the hash is
  stored.

Source: [PR #147](https://github.com/darshanbathija/Clawdmeter/pull/147).

### 1.3 Pricing snapshot fetch (read-only HTTPS)

Continuum ships a pricing snapshot at
`apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/pricing.json`.
The user can refresh it by running `./tools/refresh-pricing.sh`, which
fetches the latest pricing data from LiteLLM's public GitHub raw URL.
This is a one-way read-only HTTPS request, no body, no identifier
beyond a User-Agent and the user's IP.

A weekly GitHub Action (`.github/workflows/refresh-pricing.yml`,
shipped in B4) automates this refresh in the repo itself; users who
never invoke `refresh-pricing.sh` locally never make this request.

### 1.4 Provider CLI telemetry (third-party, opt-in by installation)

Continuum integrates five provider runtimes. Each runtime is its own
binary spawned as a child process; each owns its own network egress;
**Continuum does not proxy or inspect their traffic**.

| Provider | Egress owner | What Continuum does |
| --- | --- | --- |
| Claude Code (`claude` CLI) | Anthropic | Spawns `claude` in a direct per-session PTY, reads JSONL output, reads local auth state where allowed. Has no visibility into Claude's wire calls to Anthropic. |
| Codex app-server harness | OpenAI | Starts local Codex harness sessions and reads session JSONL. No visibility into Codex's wire calls. |
| OpenCode (`opencode serve`) | Whichever upstream providers the user has configured via `opencode auth login` — often OpenRouter, Anthropic, OpenAI | Continuum consumes OpenCode's SSE locally, sends prompts through OpenCode's HTTP API on localhost. Has no visibility into OpenCode's upstream wire calls. |
| Cursor | Anysphere | Spawns Cursor-backed sessions. No visibility into Cursor's wire calls. |
| Antigravity / Gemini | Google | Starts the headless `agy` harness. Reads conversation DB + brain-dir state. No visibility into Antigravity's upstream wire calls. |

Each provider has its own privacy policy. The user installs each
provider CLI separately and grants it credentials separately;
uninstalling a provider CLI removes its egress entirely without
affecting Continuum.

### 1.5 In-app update check

The Mac app uses Sparkle to check the public GitHub Pages appcast at
`https://darshanbathija.github.io/Continuum/updates/appcast.xml`.
When release notes or history are shown in Settings, the app also reads
static files under `https://darshanbathija.github.io/Continuum/updates/`.
These requests transmit:

- The user's IP address.
- Standard HTTPS request metadata from the OS networking stack.

It does NOT transmit any unique device identifier, install id,
session token, chat content, repo paths, or app body. GitHub Releases is
only opened when the user clicks the fallback link or Sparkle cannot
complete the update path.

Users who never want this request to fire can disable automatic checks
in Settings → Updates or firewall the Pages URL.

## 2. What stays local

The vast majority of Continuum's state stays on the user's Mac and
never crosses any network boundary Continuum controls:

- **Chat transcripts.** Live and historical chat content lives in the
  per-session JSONL files under `~/.claude/projects/`,
  `~/.codex/`, `~/.local/share/opencode/`, and analogues. Continuum
  parses these for analytics + display but does not exfiltrate them.
- **Code diffs.** The diff workbench reads from local git checkouts.
  Nothing leaves the machine.
- **Repo paths and worktrees.** Conductor worktrees, `.claude/worktrees/`,
  primary checkouts — all local. Repo identity normalization collapses
  these into the same analytics row locally; the normalized identifier
  does not leave the device.
- **Session metadata.** Session ids, model selections, terminal pane ids,
  per-session pinning, archive flags — all local. Continuum keeps a
  registry of sessions but does not sync it to any cloud.
- **JSONL ingest state.** The `IncrementalJSONLIngest` actor's
  persistent offsets (shipped in B1) and the `UsageHistoryStore`'s
  cached rollups are local.
- **Keychain entries.** Per-provider tokens, OAuth refresh tokens
  where they apply, and Continuum's pairing bearers live in the
  user's macOS Keychain. The per-instance partitioning shape lands
  with F3-wire; until then they all live in the shared Keychain
  access group.
- **F2 orchestration event store.** Append-only SQLite log of
  orchestration commands at
  `~/Library/Application Support/Clawdmeter/orchestration-events.sqlite`.
  See §3 for what this contains and how privacy-deletion works.

## 3. What the relay operator can see

The operator (us) running the Cloudflare relay Worker
([PR #151](https://github.com/darshanbathija/Clawdmeter/pull/151)) can
see:

- Source IPs of connecting peers.
- Counts of envelopes per direction and per type, with byte sizes.
- The session id presented at WebSocket open.
- TCP/TLS timing metadata.
- For session bootstrap, the SHA-256 hashes of the two per-peer
  bearer tokens (the raw tokens never reach the operator; the QR-side
  generator hashes them before transmission).

The operator CANNOT decrypt envelope contents. The session symmetric
key is derived inside the peers via X25519 ECDH + HKDF; the Worker
never observes the ECDH private keys, never holds the derived
symmetric key, and the bytes it forwards are opaque
XChaCha20-Poly1305 ciphertext.

This is enforced by Worker code (no logging of body bytes, no JSON
parse of the binary frame) and asserted by a test that plants a
literal marker string in an envelope body and assert-greps the stats
output for it. See
`infra/relay/test/relay.integration.test.ts → "stats endpoint — counts only, no body content"`.

## 4. What the APNS operator can see

The operator running the Cloudflare APNS gateway Worker
([PR #147](https://github.com/darshanbathija/Clawdmeter/pull/147)) can
see, for each push attempt:

- The SHA-256 hash of the iPhone's APNS device token (never the raw
  token in any persisted form).
- The byte size of the encrypted payload.
- The push outcome (delivered, rate-limited, kill-switched, Apple
  rejected as `Unregistered`, etc.).
- The Apple-side push delivery metadata: `apns-id`, HTTP status, any
  rejection reason.
- The sender Mac daemon's pairing fingerprint (used for audit + abuse
  attribution).
- The pairing session id.

The operator CANNOT decrypt the notification body. The body is sealed
with a sibling key derived from the same X25519 ECDH as the relay
channel (HKDF `info = "clawdmeter.apns.v1"`); only the paired iPhone
holds the matching key.

The audit log retention is 90 days (KV TTL). Workers Logs follow
Cloudflare's platform retention. See
[`docs/security.md` §7.3](security.md#73-retention) for the
operator-side controls.

## 5. Backup posture

### 5.1 SQLite event store is excluded from backup

The F2 orchestration event store (`orchestration-events.sqlite` plus
its `-wal` and `-shm` sidecars) sets the
`isExcludedFromBackupKey = true` flag at every open. This excludes the
file from iCloud, Time Machine, and any other backup mechanism that
honors the standard Apple URL resource flag.

The exclusion is re-applied after every WAL checkpoint, because
`PRAGMA wal_checkpoint(TRUNCATE)` can recreate the sidecar files with
default attributes. The check happens in `applyBackupExclusion(at:)`.

This is what keeps orchestration command history (which session was
created when, what plan was approved when, what was interrupted) off
the user's iCloud backups even though it lives in
`~/Library/Application Support/`.

### 5.2 Quarantined corrupt files are also excluded

When `OrchestrationEventStore` opens and finds a SQLite integrity
failure, it renames the broken file to `<store>.corrupt.<unixms>`
sideways and starts fresh. The rename inherits the original file's
backup-included state by default — so the broken file would sync to
iCloud as user diagnostic data.

[PR #146](https://github.com/darshanbathija/Clawdmeter/pull/146)
applies `isExcludedFromBackup = true` to each `.corrupt.<ts>` sidecar
after rename, keeping forensic state local even when the live store is
itself excluded.

### 5.3 What this means for the user

Continuum's session history, plan approval log, and orchestration
command stream are local-only by construction. Reinstalling the Mac
from a Time Machine backup will not restore them — the user starts
fresh, and the daemon's normal startup replay (from the new local
store) handles the empty case.

This is a deliberate trade-off: privacy over restorability. See
[`docs/known-limitations.md`](known-limitations.md) for the cases
where this surprises the user.

## 6. GDPR / CCPA stance

### 6.1 Right to deletion is real, not theoretical

The F2 `OrchestrationEventStore.deleteSession(_:)` method
([PR #146](https://github.com/darshanbathija/Clawdmeter/pull/146))
purges a session's orchestration history in a single SQLite
transaction:

1. `DELETE FROM events WHERE sessionId = ?`
2. `DELETE FROM session_snapshots WHERE sessionId = ?`
3. `COMMIT`
4. `PRAGMA wal_checkpoint(TRUNCATE)` — flushes the WAL so the
   deleted page images are not recoverable from `<store>-wal`.
5. Re-apply `isExcludedFromBackup` (TRUNCATE may have recreated the
   sidecars).

The WAL checkpoint step is what makes this a real privacy delete and
not a tombstone — without the checkpoint, deleted bytes linger in the
sidecar file until the next opportunistic checkpoint, leaving the
"deleted" payload recoverable. The review pass on PR #146 caught this
and added the explicit `TRUNCATE` step.

A privacy-sensitive caller can verify by checking the post-delete
file size: a fully-purged session leaves no recoverable bytes on disk.

### 6.2 Right to access

The user has full access to their data at all times — it's local on
their Mac. There is no Continuum-side server with user records to
request from; the relay and APNS gateway operators hold only the
metadata enumerated in §3 and §4.

### 6.3 Right to portability

All of the user's data is local in standard formats:

- Chat transcripts: per-provider JSONL files.
- Orchestration history: SQLite database at
  `~/Library/Application Support/Clawdmeter/orchestration-events.sqlite`.
- Pricing data: `apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/pricing.json`.

Users can read, copy, export, or destroy all of it without going
through any API.

## 7. Cookies and third-party trackers

Continuum is a native macOS / iOS / watchOS app.
There is no embedded web view used for analytics. There are no
cookies. There are no third-party trackers. There is no `localStorage`
or `IndexedDB` carrying identifiers.

The in-app Sparkle update check (§1.5) goes to static GitHub Pages
files and does not carry cookies.

## 8. Children's privacy

Continuum is a developer tool. It is not directed at children. No
data collected by Continuum is associated with named individuals
or accounts; everything is keyed by anonymous pairing session ids and
SHA-256 hashes.

## 9. Changes to this document

Material changes to the data egress story will land via a follow-up
PR with a CHANGELOG entry. The git history of this file under
`docs/privacy.md` is the audit trail.
