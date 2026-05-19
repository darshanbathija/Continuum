#!/usr/bin/env python3
"""Sidecar dispatcher for Clawdmeter SDK mode.

Spawned by `AntigravitySidecarManager.swift` when the user toggles SDK mode
ON. Receives the agent name on stdin's first JSON line, then forwards
subsequent lines to the chosen module.

Subcommands:
    observer            — long-running, observes Antigravity SDK + serves
                          the AntigravityObservation.sdk protocol over
                          stdio JSON-lines.
    session-summarizer  — nightly launchd job at 03:00 local.
    cost-pulse-watcher  — long-running watchdog over total_usage.
    repo-context-extractor — one-shot, triggered by Plan pane button.

Protocol:
    Every line on stdin is a JSON object. The first line's `agent` field
    selects the subcommand. Subsequent lines are forwarded.

    Every line on stdout is a JSON object:
        {"type": "ready"}     — sidecar initialized
        {"type": "result", "data": {...}}
        {"type": "log", "level": "info", "msg": "..."}
        {"type": "error", "msg": "..."}

The Swift side ships v0.6.0 with this as a SKELETON. Real provisioning
(uv venv + pip install google-antigravity) happens in v0.6.1; until then
this script always returns `{"type": "error", "msg": "SDK mode not yet
provisioned — toggle off."}` so the toggle's failure path is exercised
without breaking Disk mode users.
"""

from __future__ import annotations

import json
import sys
from typing import Any


def emit(obj: dict[str, Any]) -> None:
    """Write one JSON-line to stdout + flush."""
    sys.stdout.write(json.dumps(obj))
    sys.stdout.write("\n")
    sys.stdout.flush()


def main() -> int:
    emit({"type": "ready", "version": "0.6.0-skeleton"})

    # Read the first line to determine the subcommand.
    try:
        header = sys.stdin.readline()
        if not header:
            emit({"type": "error", "msg": "no header line received"})
            return 1
        cmd = json.loads(header)
    except json.JSONDecodeError as exc:
        emit({"type": "error", "msg": f"bad header JSON: {exc}"})
        return 1

    agent = cmd.get("agent")

    # v0.6.0 ships the skeleton only. Real impl lands in v0.6.1 when uv
    # provisioning is wired through AntigravitySidecarManager.
    emit({
        "type": "error",
        "code": "sdk_not_provisioned",
        "msg": (
            "SDK mode skeleton — full impl ships in v0.6.1. Toggle SDK mode "
            "off in Settings to dismiss this warning."
        ),
        "agent": agent,
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())
