#!/usr/bin/env bash
# verify-deep-research.sh — release-blocking gate for Chat V2 Deep Research.
#
# Runs each provider with a canned research prompt and asserts that the
# resulting JSONL / sidecar event stream contains:
#   1. ≥3 WebSearch / WebFetch / web_search tool invocations
#   2. a citations footer in the final assistant turn
#   3. a turn-completion marker (`result` for Claude, `turn.completed`
#      for Codex SDK, `chunk_done` / terminal frame for Antigravity)
#
# The eng-review D3 + Codex outside-voice review decided that V2 must
# either (a) ship honest Deep Research on all three providers or (b)
# not claim DR for the providers it can't verify. This script enforces
# (a). If any provider fails, the script exits non-zero and CI red-
# lights the v0.23.0 release.
#
# Usage:
#   tools/verify-deep-research.sh                     # all three providers
#   tools/verify-deep-research.sh claude              # one provider
#   tools/verify-deep-research.sh --prompt "..."      # custom seed
#
# Exit codes:
#   0 — every requested provider passed all three assertions.
#   1 — at least one provider failed; per-provider results printed.
#   2 — environment unfit (missing CLI, daemon unreachable, etc).
#
# Notes for the reviewer:
# - Walltime budget per provider: 10 minutes. Deep Research is meant
#   to be slow — the gate is correctness, not speed.
# - The canned prompt is intentionally one where any of the three
#   models WILL want to web-search (current events question); change
#   `DEFAULT_PROMPT` if the question goes stale.
# - This script does NOT exercise the V2 UI — it talks to the
#   daemon's HTTP/WS surface directly so it can run in CI without
#   spawning the app.
# - Cleanup: each provider's spawned chat session is archived at
#   end-of-test so the registry doesn't accumulate test sessions.

set -euo pipefail

DAEMON_HOST="${CLAWDMETER_DAEMON_HOST:-127.0.0.1}"
DAEMON_PORT="${CLAWDMETER_DAEMON_PORT:-21731}"
DAEMON_TOKEN="${CLAWDMETER_DAEMON_TOKEN:-}"
DEFAULT_PROMPT="${VERIFY_DR_PROMPT:-What shipped in macOS 26 Tahoe? Cite specific sources.}"
MIN_TOOL_CALLS="${VERIFY_DR_MIN_TOOL_CALLS:-3}"
TURN_TIMEOUT_SEC="${VERIFY_DR_TURN_TIMEOUT_SEC:-600}"
POLL_INTERVAL_SEC=2

# Color helpers.
if [[ -t 1 ]]; then
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YEL='\033[33m'; C_DIM='\033[2m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YEL=''; C_DIM=''; C_RESET=''
fi

die() {
  printf '%sFAIL%s: %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit "${2:-1}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1" 2
}

require_cmd curl
require_cmd jq

if [[ "${CLAWDMETER_ALLOW_PROVIDER_SPEND:-0}" != "1" ]]; then
  die "Deep Research verification sends live provider prompts; set CLAWDMETER_ALLOW_PROVIDER_SPEND=1 and launch the daemon with CLAWDMETER_LIVE_PROVIDER_TESTS=1 to run it" 2
fi

if [[ -z "$DAEMON_TOKEN" ]]; then
  echo "${C_YEL}NOTE${C_RESET}: \$CLAWDMETER_DAEMON_TOKEN not set; fetching from PairingTokenStore default file."
  # The token store writes a file under Application Support — read it
  # if we can; otherwise the caller has to set the env var.
  TOKEN_FILE="${HOME}/Library/Application Support/Clawdmeter/pairing-token"
  if [[ -f "$TOKEN_FILE" ]]; then
    DAEMON_TOKEN="$(cat "$TOKEN_FILE")"
  else
    die "no token; set CLAWDMETER_DAEMON_TOKEN or run the Mac app first" 2
  fi
fi

DAEMON_URL="http://${DAEMON_HOST}:${DAEMON_PORT}"
AUTH=(-H "Authorization: Bearer ${DAEMON_TOKEN}")

# Probe /health.
health="$(curl -fsS "${DAEMON_URL}/health" "${AUTH[@]}" || true)"
if [[ -z "$health" ]]; then
  die "daemon unreachable at ${DAEMON_URL}/health" 2
fi
wire="$(printf '%s' "$health" | jq -r '.wireVersion // empty')"
if [[ -z "$wire" || "$wire" -lt 14 ]]; then
  die "daemon wire version $wire < 14 — Deep Research wiring missing" 2
fi

# Filter providers from argv.
PROVIDERS=()
for arg in "$@"; do
  case "$arg" in
    --prompt)
      shift
      DEFAULT_PROMPT="$1"
      shift
      ;;
    claude|codex|gemini)
      PROVIDERS+=("$arg")
      ;;
    --help|-h)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      die "unknown arg: $arg" 2
      ;;
  esac
done
if [[ ${#PROVIDERS[@]} -eq 0 ]]; then
  PROVIDERS=(claude codex gemini)
fi

# Per-provider assertion runner.
verify_provider() {
  local provider="$1"
  local label="${C_DIM}${provider}${C_RESET}"
  printf '\n=== %s ===\n' "$label"

  # 1. Create a Deep Research chat session.
  local create_body
  create_body="$(printf '%s' '{"provider":"PROVIDER","deepResearch":true}' | sed "s/PROVIDER/${provider}/")"
  local create_resp
  create_resp="$(curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "$create_body" "${AUTH[@]}" "${DAEMON_URL}/chat-sessions" || true)"
  local session_id
  session_id="$(printf '%s' "$create_resp" | jq -r '.id // empty')"
  if [[ -z "$session_id" ]]; then
    printf '%sFAIL%s %s: createChatSession returned no id\nResp: %s\n' \
      "$C_RED" "$C_RESET" "$provider" "$create_resp"
    return 1
  fi
  printf '  session: %s\n' "$session_id"

  # 2. Send the canned research prompt.
  local send_body
  send_body="$(jq -n --arg t "$DEFAULT_PROMPT" --arg id "$(uuidgen)" \
    '{text:$t, asFollowUp:false, origin:"liveProviderTest", clientIntentId:$id}')"
  curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "$send_body" "${AUTH[@]}" \
    "${DAEMON_URL}/sessions/${session_id}/send" >/dev/null || true
  printf '  prompt sent; waiting up to %ss for completion…\n' "$TURN_TIMEOUT_SEC"

  # 3. Poll /sessions/:id/chat-snapshot until currentTurnState is
  #    .completed or timeout.
  local deadline=$(( $(date +%s) + TURN_TIMEOUT_SEC ))
  local snapshot=""
  local turn_state=""
  while [[ $(date +%s) -lt $deadline ]]; do
    snapshot="$(curl -fsS "${AUTH[@]}" \
      "${DAEMON_URL}/sessions/${session_id}/chat-snapshot" || true)"
    turn_state="$(printf '%s' "$snapshot" | jq -r '.currentTurnState // "idle"')"
    if [[ "$turn_state" == "completed" || "$turn_state" == "interrupted" ]]; then
      break
    fi
    sleep "$POLL_INTERVAL_SEC"
  done

  if [[ "$turn_state" != "completed" ]]; then
    printf '%sFAIL%s %s: turn did not complete (state=%s)\n' \
      "$C_RED" "$C_RESET" "$provider" "$turn_state"
    return 1
  fi

  # 4. Assertion A: ≥MIN_TOOL_CALLS WebSearch / WebFetch / web_search calls.
  local tool_calls
  tool_calls="$(printf '%s' "$snapshot" | jq '
    [.items[]
      | .toolRun?.pairs[]?.call.title
      | select(. != null and (
          . == "WebSearch" or . == "WebFetch" or
          . == "web_search" or . == "web_fetch"
        ))
    ] | length
  ')"
  if [[ -z "$tool_calls" ]]; then tool_calls=0; fi

  # 5. Assertion B: assistant final message contains a citations
  #    marker — either `[^N]:` footnote OR a "## Sources" heading.
  local citations
  citations="$(printf '%s' "$snapshot" | jq -r '
    [.items[]
      | .message?
      | select(.kind == "assistantText")
      | .body
    ] | last // ""
  ')"
  local has_citation="no"
  if printf '%s' "$citations" | grep -qE '(\[\^[0-9]+\]|## Sources)'; then
    has_citation="yes"
  fi

  # 6. Report.
  local pass="yes"
  printf '  tool calls (search/fetch): %s (need ≥ %s)\n' "$tool_calls" "$MIN_TOOL_CALLS"
  if (( tool_calls < MIN_TOOL_CALLS )); then pass="no"; fi
  printf '  citations footer: %s\n' "$has_citation"
  if [[ "$has_citation" == "no" ]]; then pass="no"; fi

  # 7. Cleanup (best-effort archive).
  curl -fsS -X POST "${AUTH[@]}" \
    -H 'Content-Type: application/json' -d '{"reason":"verify-deep-research"}' \
    "${DAEMON_URL}/sessions/${session_id}/archive" >/dev/null 2>&1 || true

  if [[ "$pass" == "yes" ]]; then
    printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$provider"
    return 0
  else
    printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$provider"
    return 1
  fi
}

overall=0
for provider in "${PROVIDERS[@]}"; do
  if ! verify_provider "$provider"; then
    overall=1
  fi
done

echo
if [[ $overall -eq 0 ]]; then
  printf '%sAll providers passed Deep Research verification.%s\n' "$C_GREEN" "$C_RESET"
else
  printf '%sDeep Research verification FAILED for one or more providers.%s\n' "$C_RED" "$C_RESET"
fi
exit "$overall"
