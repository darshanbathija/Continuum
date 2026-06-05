# clawdmeter-agents

Python sidecar for Continuum SDK mode (Antigravity 2 native, v0.6.0+).

**Status: skeleton.** Real implementation lands in v0.6.1.

## Subcommands

- `observer` — long-running observation bridge for the Plan pane + analytics.
- `session-summarizer` — nightly launchd job at 03:00 local.
- `cost-pulse-watcher` — burn-rate watcher with APNS push alerts.
- `repo-context-extractor` — one-shot agent triggered by the Plan pane button.

## Local testing

```bash
cd tools/clawdmeter-agents
python3 main.py < /dev/null
```

Expected output (v0.6.0 skeleton):

```json
{"type":"ready","version":"0.6.0-skeleton"}
{"type":"error","code":"sdk_not_provisioned",...}
```

## Provisioning

The Mac daemon's `AntigravitySidecarManager.swift` will, when SDK mode is
toggled ON, run:

```bash
uv venv ~/Library/Application\ Support/Clawdmeter/python/
uv pip install google-antigravity~=0.0.3
```

That step ships in v0.6.1 — v0.6.0 toggle currently always reverts to OFF
after surfacing the skeleton's "sdk_not_provisioned" error in Settings →
Diagnostics.
