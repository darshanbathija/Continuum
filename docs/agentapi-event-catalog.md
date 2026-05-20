# agentapi event catalog — Phase 0 verification spike

Status: **PENDING — blocked on OAuth.** See `docs/agentapi-runtime-notes.md` Production-blocking finding.

## Method (once auth is in place)

```bash
LS="/Applications/Antigravity.app/Contents/Resources/bin/language_server"
# Start daemon
"$LS" -persistent_mode=true -local_chrome_headless=true -disable_telemetry=true \
      -app_data_dir=clawdmeter-cli-spike-$(date +%s) \
      -http_server_port=0 -csrf_token="$(uuidgen)" > /tmp/ls-daemon.log 2>&1 &
LS_PID=$!
sleep 1
# Parse port from log
LS_PORT=$(grep "for HTTP" /tmp/ls-daemon.log | grep -oE '[0-9]+ for HTTP' | head -1 | grep -oE '^[0-9]+')
export ANTIGRAVITY_LS_ADDRESS="http://127.0.0.1:$LS_PORT"

# Capture event stream
"$LS" agentapi new-conversation --model=flash "Write a haiku about Antigravity" \
      2>&1 | tee /tmp/agentapi-events.log

# Send a follow-up
CONV_ID="<from new-conversation stdout>"
"$LS" agentapi send-message "$CONV_ID" "Now translate it to French" \
      2>&1 | tee -a /tmp/agentapi-events.log

# Teardown
kill $LS_PID
```

Then for each line in `/tmp/agentapi-events.log` matching JSON, enumerate distinct `type` field values. Each distinct type → row in the catalog table below.

## Expected event types (per binary-strings evidence, unverified)

Based on Codex SDK parallel:

| event type | when emitted | payload fields | maps to ChatItem | priority |
|---|---|---|---|---|
| `ready` | sidecar bootstrap complete | `version`, etc. | (consumed by manager) | P0 |
| `conversation_started` | new-conversation initial response | `conversation_id` | (consumed by relay) | P0 |
| `agent_message` | model produced text | `text`, `chunk_index`? | `.assistantText` | P0 |
| `reasoning` | model produced reasoning trace | `text` | `.meta(title:"Reasoning")` | P1 |
| `tool_call` | model invoked a tool | `tool_name`, `input` | `.toolCall` | P1 |
| `tool_result` | tool returned | `tool_name`, `output`, `status` | `.toolResult` | P1 |
| `usage_update` | token totals updated | `input`, `output`, `cached`, `thoughts` | `appendSDKMessages([], delta*)` | P0 |
| `turn_completed` | end of turn | final `usage` | (consumed) | P0 |
| `error` | non-fatal error | `code`, `msg` | `.meta` red | P0 |

These are guesses. Phase 0 fills in real types after auth.

## Edge cases to capture

- Streaming mid-turn shutdown (Ctrl+C the agentapi process)
- Auth expiry mid-stream
- Tool-call output exceeds reasonable size
- Multiple parallel `send-message` calls against same conversation
- `get-conversation-metadata` for in-flight conversation vs completed

These shape `AntigravitySDKEventIngestor`'s error-handling.
