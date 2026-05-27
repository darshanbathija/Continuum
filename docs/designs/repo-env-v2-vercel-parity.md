# Repo Env Variables V2: Vercel-Comparable Manager

## Summary

V1 gives Clawdmeter a secure repo-first environment-variable system: metadata in Application Support JSON, values in Keychain, per-repo sets, per-variable set assignment, managed `.env.local` materialization, and runtime injection where supported.

V2 should turn that foundation into a full environment manager comparable to Vercel's environment-variable UI while staying native to `DESIGN.md`: Tahoe glass preference cards, dense operational tables, real controls, masked secrets, and no fake web chrome.

## V1 Baseline

- Settings has an Env Variables section.
- A repo can define sets such as `local`, `testnet`, `staging`, and `prod`.
- Variables can be repo-local or shared across repos.
- Variables can be enabled or disabled per set.
- Values are stored in Keychain and not serialized in JSON.
- Runtime launch resolves one pinned set per session, writes the managed `.env.local` block, and injects process env where supported.
- Manual `.env.local` conflicts are preserved and shown for adopt/import resolution.

## V2 Product Goal

Developers should be able to manage env vars in Clawdmeter with the same confidence they get from Vercel:

- Scan all variables in a real table.
- Search, filter, and sort large env lists.
- Add one variable or bulk-import `.env` contents.
- Assign variables to multiple repos and multiple sets at creation time.
- Safely inspect, edit, rotate, duplicate, delete, and audit variables.
- Understand exactly which sessions and run profiles will receive a variable.
- Resolve local `.env.local` conflicts without Clawdmeter overwriting manual work.

## Design Contract

Follow `DESIGN.md`:

- Settings remains organized into preference cards.
- The table is a dense native control surface, not a marketing dashboard.
- Use Tahoe glass, Apple system fonts, hairlines, compact menus, segmented controls, and native sheets/drawers.
- Values remain masked by default.
- Every visible command must be wired to real behavior or explicitly disabled with clear copy.
- Do not introduce a one-note Vercel-white web UI; borrow the information architecture, not the styling.

## Vercel-Parity Surface

### Main Table

Columns:

- `Key`: monospace key, source badge, optional note indicator.
- `Sets`: chips for `local`, `testnet`, `staging`, `prod`, custom sets, and overflow.
- `Repos`: current repo, multi-repo shared count, and quick popover.
- `Value`: masked value with reveal/edit controls behind confirmation.
- `Type`: plain/sensitive/system/inherited.
- `Last Updated`: relative time plus editor identity when available.
- `Status`: conflict, missing secret, materialized, not in active set.
- `Actions`: edit, duplicate, rotate, copy key, copy masked reference, enable all sets, disable set, delete.

Controls:

- Scope tabs: `Project`, `Shared`, `System`.
- Search variables.
- Set filter: all sets or one set.
- Repo filter: current repo, all selected repos, unassigned.
- Type filter: all, plain, sensitive, missing value, conflicts.
- Sort: last updated, key A-Z, source, set count, conflict status.
- Bulk selection with batch enable/disable/delete/export metadata.

### Add/Edit Drawer

Fields:

- Key.
- Value with masked entry and reveal toggle.
- Optional note.
- Type: sensitive by default, plain only by explicit choice.
- Repos multi-select.
- Sets multi-select per selected repo.
- Branch selector for provider-specific preview flows in V3; hidden in V2 unless implemented.
- Add another.
- Save pinned footer.

Import:

- `Import .env` button opens file picker.
- Paste `.env` contents into a parser field.
- Preview parsed keys before save.
- Detect duplicates, invalid keys, empty values, comments, quoted values, multiline values, and export-style prefixes.
- Let users choose overwrite, skip, or create disabled draft rows.
- Import never writes secrets to JSON before Keychain writes succeed.

### Manual `.env.local` Conflict Flow

- Show manual keys outside the managed block in a conflict table.
- Actions: adopt, import copy, ignore, open file, remove manual line after confirmation.
- Runtime launch blocks on typed conflicts and links back to the exact conflict row.
- The materializer still updates only the Clawdmeter-managed block.

### Variable Detail

Clicking a row opens a detail drawer:

- Assignment matrix by repo and set.
- Keychain value state without eager reads.
- Last modified metadata.
- Recent materialization targets.
- Sessions currently pinned to a set containing the variable.
- Conflict history and resolution status.

## Data Model Additions

Add metadata only:

- `RepoEnvVariableRecord.note: String?`
- `RepoEnvVariableRecord.kind: plain | sensitive | system`
- `RepoEnvVariableRecord.createdBy: String?`
- `RepoEnvVariableRecord.updatedBy: String?`
- `RepoEnvVariableRecord.lastRotatedAt: Date?`
- `RepoEnvVariableRecord.disabledAt: Date?`
- `RepoEnvImportBatchRecord`
- `RepoEnvAuditEventRecord`

Do not store secret values, plaintext previews, or revealed-value timestamps in metadata JSON.

## Runtime Additions

- Session launch sheet should expose env-set selection before spawn.
- Existing sessions keep pinned set semantics.
- Run profiles should show the pinned env set and resolved-variable count.
- Materialization should report changed keys, conflicts, and skipped keys.
- OpenCode v1 remains `.env.local` materialization only until its singleton process can support safe per-session env.

## Security Requirements

- Keychain write must complete before metadata says a value exists.
- Reveal requires deliberate user action and never logs value contents.
- Copy value should be time-limited UI state and never persist to telemetry.
- Table renders from metadata only; no eager Keychain reads.
- Bulk import validates all keys before writing any secret.
- Delete removes Keychain value and metadata assignment together, with recoverable confirmation copy that excludes values.

## Test Plan

- XCTest: import parser, duplicate handling, quoted/multiline/env-export parsing.
- XCTest: metadata remains secret-free across add/edit/import/rotate/delete.
- XCTest: per-repo/per-set assignment matrix defaults and overrides.
- XCTest: conflict launch failure links to conflict record.
- XCTest: value reveal/copy paths never log secret values.
- XCTest: audit events exclude values.
- XCUITest: table search/filter/sort, add drawer, import preview, conflict resolution, shared variable across repos, remove from one repo set.
- Focused macOS build and signed UI test pass before PR.

## Rollout

1. Table hardening: persistent filters, bulk selection, row detail drawer.
2. Add/edit drawer: note, sensitivity, add-another, full assignment matrix.
3. Import parser and preview flow.
4. Conflict resolution deep links from launch failures.
5. Audit metadata and rotation workflows.
6. Session/run-profile env-set picker polish.

## Non-Goals For V2

- Cloud sync of env values.
- Team permissions.
- Provider-hosted secret storage.
- Per-branch Vercel preview semantics unless the branch selector is fully wired.
