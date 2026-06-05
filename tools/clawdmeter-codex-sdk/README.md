# clawdmeter-codex-sdk

Node sidecar for Continuum Codex SDK observation mode (v0.7.0+).

**Status: skeleton.** Real implementation lands in v0.7.1.

## Why a Node sidecar for Codex when Antigravity is Python?

- The Codex SDK is **stable in TypeScript**, **experimental in Python**.
  We pick the stable surface.
- Node is already a transitive dependency on most dev machines: Codex
  itself is `npm install -g @openai/codex`. If `codex` runs, `node` runs.
- Provisioning is one `npm install @openai/codex-sdk` away (v0.7.1).

## Subcommands

- `observer` — long-running observation bridge for the Sessions IDE
  chat pane + analytics. Wraps the SDK's `thread.runStreamed()` to emit
  `item.completed` and `turn.completed` events with token usage —
  cutting latency from ~1s JSONL tail polling to live streaming.
- `resume` — one-shot. `codex.resumeThread(threadId).run(prompt)` for
  iOS→Mac spawn-handoff (the X1 cross-Apple compose-draft flow could
  resume a Codex thread on the Mac when the user taps "Open on Mac"
  from iPhone).

## Authentication

Verified on dev machine 2026-05-20: when the user runs `codex login`
and selects the ChatGPT plan path, `~/.codex/auth.json` sets
`auth_mode: "chatgpt"` and stores OAuth tokens locally. The SDK
inherits this automatically — **no API key required, no per-token
billing**. Usage draws against the ChatGPT Plus/Pro/Team subscription
quota.

This is the structural reason the Codex SDK is opt-in-safe for paid
ChatGPT users in a way the Claude Agent SDK is not. (Anthropic
explicitly disallows claude.ai login in third-party SDK products.)

## Local testing

```bash
cd tools/clawdmeter-codex-sdk
echo '{"agent":"observer"}' | node main.mjs
```

Expected output (v0.7.0 skeleton):

```json
{"type":"ready","version":"0.7.0-skeleton"}
{"type":"error","code":"sdk_not_provisioned",...}
```

## Provisioning (v0.7.1)

`CodexSDKManager.swift` will, on toggle ON:

```bash
cd ~/Library/Application\ Support/Clawdmeter/codex-sdk/
npm install @openai/codex-sdk
```

Steady-state cost: ~10 MB of node_modules + one long-running Node
process when SDK mode is active. Steady-state benefit: live token
streaming instead of 1s JSONL tail polling, structured tool-call
event observation, programmatic thread resumption.
