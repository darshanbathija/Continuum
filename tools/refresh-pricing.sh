#!/usr/bin/env bash
# Refresh apple/ClawdmeterShared/.../Analytics/pricing.json from the upstream
# LiteLLM model pricing table. Idempotent. Run by hand whenever LiteLLM pushes
# new rates (roughly quarterly).
#
# Per plan A20 + A3: we ship an embedded snapshot rather than fetching at
# runtime so analytics works offline and our totals are reproducible.
#
# Filter rule: keep keys matching `claude-*`, `gpt-*`, `o[0-9]+*`,
# `gemini-*`, or `gemma-*` so the snapshot covers Anthropic + OpenAI/Codex
# + Google (Gemini provider added 2026-05-19) without dragging in every
# random provider LiteLLM tracks.
#
# Usage:
#   ./tools/refresh-pricing.sh
#
# Requires: curl, jq.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/apple/ClawdmeterShared/Sources/ClawdmeterShared/Analytics/pricing.json"
SRC="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

echo "Fetching $SRC..."
RAW="$(mktemp)"
trap 'rm -f "$RAW"' EXIT
curl -fsSL "$SRC" -o "$RAW"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Filtering to claude-* / gpt-* / o[0-9]* / chatgpt-* / gemini-* / gemma-* models..."
jq --arg src "$SRC" --arg ts "$NOW" '
  to_entries
  | map(select(
      .key | test("^(claude-|gpt-|o[0-9]+($|-)|chatgpt-|gemini-|gemma-)"; "i")
    ))
  | from_entries
  | { _meta: { source: $src, capturedAt: $ts }, models: . }
' "$RAW" > "$OUT"

KEYS=$(jq '.models | length' "$OUT")
echo "Wrote $OUT ($KEYS models)"
