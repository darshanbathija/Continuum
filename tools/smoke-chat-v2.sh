#!/usr/bin/env bash
# smoke-chat-v2.sh — basic round-trip smoke test for V2 chat.
#
# Proves the simple chat path works for each provider BEFORE the
# Deep Research gate runs:
#   1. solo Claude / Codex / Gemini — create chat, send prompt, see
#      currentTurnState=completed + assistant text in the snapshot.
#   2. broadcast — create a frontier session over all three providers,
#      send one prompt, see each slot's snapshot complete with text.
#
# Usage:
#   tools/smoke-chat-v2.sh                       # all + broadcast
#   tools/smoke-chat-v2.sh claude codex          # only those, no broadcast
#   tools/smoke-chat-v2.sh --broadcast-only      # frontier only
#   tools/smoke-chat-v2.sh --no-broadcast        # skip the frontier slot
#   tools/smoke-chat-v2.sh --prompt "..."        # custom seed

set -euo pipefail

DAEMON_HOST="${CLAWDMETER_DAEMON_HOST:-127.0.0.1}"
DAEMON_PORT="${CLAWDMETER_DAEMON_PORT:-21731}"
DAEMON_TOKEN="${CLAWDMETER_DAEMON_TOKEN:-}"
DEFAULT_PROMPT="${SMOKE_PROMPT:-Say hi in one short sentence.}"
TURN_TIMEOUT_SEC="${SMOKE_TURN_TIMEOUT_SEC:-180}"
POLL_INTERVAL_SEC=1

if [[ -t 1 ]]; then
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YEL='\033[33m'; C_DIM='\033[2m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YEL=''; C_DIM=''; C_RESET=''
fi

die() { printf '%sFAIL%s: %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit "${2:-1}"; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing: $1" 2; }
require curl
require jq

if [[ -z "$DAEMON_TOKEN" ]]; then
  DAEMON_TOKEN="$(security find-generic-password -s 'com.clawdmeter.mac.pairing' -a 'daemon-bearer-token' -w 2>/dev/null || true)"
  [[ -z "$DAEMON_TOKEN" ]] && die "no daemon token in keychain" 2
fi

DAEMON_URL="http://${DAEMON_HOST}:${DAEMON_PORT}"
AUTH=(-H "Authorization: Bearer ${DAEMON_TOKEN}")

health="$(curl -fsS "${DAEMON_URL}/health" "${AUTH[@]}" || true)"
wire="$(printf '%s' "$health" | jq -r '.wireVersion // empty')"
[[ -z "$wire" || "$wire" -lt 14 ]] && die "wire $wire < 14" 2
printf 'daemon: wire=%s server=%s\n' "$wire" "$(printf '%s' "$health" | jq -r '.serverVersion')"

PROVIDERS=()
BROADCAST_ONLY=0
INCLUDE_BROADCAST=0
EXPLICIT_BROADCAST=0
for arg in "$@"; do
  case "$arg" in
    --prompt) shift; DEFAULT_PROMPT="$1"; shift ;;
    --broadcast-only) BROADCAST_ONLY=1; INCLUDE_BROADCAST=1; EXPLICIT_BROADCAST=1 ;;
    --no-broadcast) INCLUDE_BROADCAST=0; EXPLICIT_BROADCAST=1 ;;
    claude|codex|gemini) PROVIDERS+=("$arg") ;;
  esac
done
if [[ ${#PROVIDERS[@]} -eq 0 && $BROADCAST_ONLY -eq 0 ]]; then
  PROVIDERS=(claude codex gemini)
  [[ $EXPLICIT_BROADCAST -eq 0 ]] && INCLUDE_BROADCAST=1
fi

PASS_COUNT=0
FAIL_COUNT=0
FAIL_LIST=()

# Pull the latest assistant body from a chat-snapshot blob.
extract_assistant() {
  jq -r '[.items[]?.message?._0? | select(.kind=="assistantText") | .body] | last // ""'
}

solo_smoke() {
  local provider="$1"
  printf '\n=== solo %s ===\n' "$provider"

  local create_resp session_id
  create_resp="$(curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "{\"provider\":\"$provider\"}" "${AUTH[@]}" "${DAEMON_URL}/chat-sessions" || true)"
  session_id="$(printf '%s' "$create_resp" | jq -r '.id // empty')"
  if [[ -z "$session_id" ]]; then
    printf '  %sFAIL%s create: %s\n' "$C_RED" "$C_RESET" "$create_resp"
    FAIL_COUNT=$((FAIL_COUNT+1)); FAIL_LIST+=("$provider"); return 1
  fi
  printf '  session=%s\n' "$session_id"

  local send_body
  send_body="$(jq -n --arg t "$DEFAULT_PROMPT" '{text:$t, asFollowUp:false}')"
  curl -fsS -X POST -H 'Content-Type: application/json' -d "$send_body" "${AUTH[@]}" \
    "${DAEMON_URL}/sessions/${session_id}/send" >/dev/null || true
  printf '  sent, polling up to %ss…\n' "$TURN_TIMEOUT_SEC"

  local started=$(date +%s)
  local deadline=$(( started + TURN_TIMEOUT_SEC ))
  local snapshot turn_state last_state=""
  while [[ $(date +%s) -lt $deadline ]]; do
    snapshot="$(curl -fsS "${AUTH[@]}" "${DAEMON_URL}/sessions/${session_id}/chat-snapshot" || true)"
    turn_state="$(printf '%s' "$snapshot" | jq -r '.currentTurnState // "idle"')"
    if [[ "$turn_state" != "$last_state" ]]; then
      printf '  state -> %s (t+%ss)\n' "$turn_state" "$(($(date +%s) - started))"
      last_state="$turn_state"
    fi
    if [[ "$turn_state" == "completed" || "$turn_state" == "interrupted" ]]; then break; fi
    sleep "$POLL_INTERVAL_SEC"
  done

  local assistant
  assistant="$(printf '%s' "$snapshot" | extract_assistant)"
  local item_count
  item_count="$(printf '%s' "$snapshot" | jq '.items // [] | length')"

  printf '  final state: %s\n' "$turn_state"
  printf '  items=%s assistant: %s\n' "$item_count" "$(printf '%s' "$assistant" | head -1 | cut -c1-120)"

  if [[ "$turn_state" == "completed" && -n "$assistant" ]]; then
    printf '  %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$provider"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    printf '  %sFAIL%s %s: state=%s assistant=%s\n' "$C_RED" "$C_RESET" "$provider" "$turn_state" \
      "$([[ -z "$assistant" ]] && echo empty || echo nonempty)"
    FAIL_COUNT=$((FAIL_COUNT+1)); FAIL_LIST+=("$provider")
  fi
}

broadcast_smoke() {
  printf '\n=== broadcast (claude + codex + gemini) ===\n'
  local create_body create_resp frontier_id slots
  create_body='{"slots":[{"provider":"claude"},{"provider":"codex"},{"provider":"gemini"}]}'
  create_resp="$(curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "$create_body" "${AUTH[@]}" "${DAEMON_URL}/chat-sessions/frontier" || true)"
  frontier_id="$(printf '%s' "$create_resp" | jq -r '.id // empty')"
  if [[ -z "$frontier_id" ]]; then
    printf '  %sFAIL%s frontier create: %s\n' "$C_RED" "$C_RESET" "$create_resp"
    FAIL_COUNT=$((FAIL_COUNT+1)); FAIL_LIST+=("broadcast"); return 1
  fi
  slots="$(printf '%s' "$create_resp" | jq -r '[.slots[]? | (.sessionId // .id // empty)] | map(select(length>0)) | join(" ")')"
  printf '  frontier=%s\n' "$frontier_id"
  printf '  slots: %s\n' "$slots"
  [[ -z "$slots" ]] && { printf '  %sFAIL%s no slot ids in response: %s\n' "$C_RED" "$C_RESET" "$create_resp"; FAIL_COUNT=$((FAIL_COUNT+1)); FAIL_LIST+=("broadcast"); return 1; }

  local send_body
  send_body="$(jq -n --arg t "$DEFAULT_PROMPT" '{text:$t, asFollowUp:false}')"
  curl -fsS -X POST -H 'Content-Type: application/json' -d "$send_body" "${AUTH[@]}" \
    "${DAEMON_URL}/chat-sessions/frontier/${frontier_id}/send" >/dev/null || true
  printf '  sent, polling each slot up to %ss…\n' "$TURN_TIMEOUT_SEC"

  local started=$(date +%s)
  local deadline=$(( started + TURN_TIMEOUT_SEC ))
  declare -A LAST_STATE
  local all_done=0
  while [[ $(date +%s) -lt $deadline && $all_done -eq 0 ]]; do
    all_done=1
    for sid in $slots; do
      local snap state
      snap="$(curl -fsS "${AUTH[@]}" "${DAEMON_URL}/sessions/${sid}/chat-snapshot" || true)"
      state="$(printf '%s' "$snap" | jq -r '.currentTurnState // "idle"')"
      if [[ "${LAST_STATE[$sid]:-}" != "$state" ]]; then
        printf '    %s -> %s (t+%ss)\n' "$sid" "$state" "$(($(date +%s) - started))"
        LAST_STATE[$sid]="$state"
      fi
      if [[ "$state" != "completed" && "$state" != "interrupted" ]]; then all_done=0; fi
    done
    [[ $all_done -eq 1 ]] && break
    sleep "$POLL_INTERVAL_SEC"
  done

  local pass=1
  for sid in $slots; do
    local snap state assistant
    snap="$(curl -fsS "${AUTH[@]}" "${DAEMON_URL}/sessions/${sid}/chat-snapshot" || true)"
    state="$(printf '%s' "$snap" | jq -r '.currentTurnState // "idle"')"
    assistant="$(printf '%s' "$snap" | extract_assistant)"
    printf '  %s state=%s | %s\n' "$sid" "$state" "$(printf '%s' "$assistant" | head -1 | cut -c1-100)"
    if [[ "$state" != "completed" || -z "$assistant" ]]; then pass=0; fi
  done

  if [[ $pass -eq 1 ]]; then
    printf '  %sPASS%s broadcast (all 3 slots completed with text)\n' "$C_GREEN" "$C_RESET"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    printf '  %sFAIL%s broadcast\n' "$C_RED" "$C_RESET"
    FAIL_COUNT=$((FAIL_COUNT+1)); FAIL_LIST+=("broadcast")
  fi
}

if [[ $BROADCAST_ONLY -eq 0 ]]; then
  for p in "${PROVIDERS[@]}"; do solo_smoke "$p" || true; done
fi
if [[ $INCLUDE_BROADCAST -eq 1 ]]; then
  broadcast_smoke || true
fi

printf '\n--- summary ---\n'
printf 'pass=%s fail=%s\n' "$PASS_COUNT" "$FAIL_COUNT"
if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'failed: %s\n' "${FAIL_LIST[*]}"
  exit 1
fi
exit 0
