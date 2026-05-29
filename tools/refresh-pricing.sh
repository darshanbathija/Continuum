#!/usr/bin/env bash
# Refresh apple/ClawdmeterShared/.../Analytics/pricing.json from the upstream
# LiteLLM model pricing table. Idempotent. Run by hand whenever LiteLLM pushes
# new rates (roughly quarterly).
#
# Per plan A20 + A3: we ship an embedded snapshot rather than fetching at
# runtime so analytics works offline and our totals are reproducible.
#
# Filter rule: keep keys matching `claude-*`, `gpt-*`, `o[0-9]+*`,
# `chatgpt-*`, `gemini-*`, `gemma-*`, or `grok-*` / `xai/*` so the snapshot
# covers Anthropic + OpenAI/Codex + Google (Gemini, added 2026-05-19) + xAI
# (Grok, added 2026-05-29 — used via the opencode provider) without dragging
# in every random provider LiteLLM tracks.
#
# Override merge (added 2026-05-23): after filtering LiteLLM, we apply
# entries from `tools/pricing-overrides.json` on top. Overrides win.
# This exists because:
#   - Google's I/O 2026 (2026-05-19) announced gemini-3.5-flash at $1.50/$9
#     and gemini-3.1-pro at $2/$12. LiteLLM may not have shipped these
#     rates yet on the day we refresh. Without overrides, refreshing would
#     silently revert pricing.json to LiteLLM's stale numbers and
#     Antigravity costs would drop by 5-30× until LiteLLM caught up.
#   - The override file is the audit trail: it explains *why* each manual
#     entry exists with a `_note` field, and the `_meta.policy` field
#     says to drop entries once LiteLLM catches up.
#
# Usage:
#   ./tools/refresh-pricing.sh
#
# Requires: curl, jq.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/pricing.json"
OVERRIDES="$REPO_ROOT/tools/pricing-overrides.json"
SRC="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

echo "Fetching $SRC..."
RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT
curl -fsSL "$SRC" -o "$RAW"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Build the manual-overrides summary line from the override keys so the
# audit trail in pricing.json's _meta block stays in sync with whatever
# tools/pricing-overrides.json carries.
OVERRIDE_SUMMARY="$(jq -r '
  .overrides
  | to_entries
  | map("\(.key): \(.value._note // "manual override")")
  | join(" | ")
' "$OVERRIDES")"

echo "Filtering to claude-* / gpt-* / o[0-9]* / chatgpt-* / gemini-* / gemma-* / grok-* / xai/* models..."
echo "Merging manual overrides from $OVERRIDES..."

jq \
  --arg src "$SRC" \
  --arg ts "$NOW" \
  --arg summary "$OVERRIDE_SUMMARY" \
  --slurpfile overrides "$OVERRIDES" \
'
  # Step 1: filter LiteLLM to the providers Clawdmeter cares about.
  to_entries
  | map(select(
      .key | test("^(claude-|gpt-|o[0-9]+($|-)|chatgpt-|gemini-|gemma-|grok-|xai/)"; "i")
    ))
  | from_entries
  # Step 2: apply manual overrides on top. `+` in jq is a shallow merge
  # where the right side wins per key, which is exactly what we want:
  # any override entry replaces the upstream entry wholesale; entries
  # that exist only in LiteLLM pass through; entries only in overrides
  # get added.
  | . + ($overrides[0].overrides)
  | { _meta: { source: $src, capturedAt: $ts, manualOverrides: $summary }, models: . }
' "$RAW" > "$OUT"

KEYS=$(jq '.models | length' "$OUT")
OVERRIDE_KEYS=$(jq '.overrides | length' "$OVERRIDES")
echo "Wrote $OUT ($KEYS models, including $OVERRIDE_KEYS manual overrides)"
