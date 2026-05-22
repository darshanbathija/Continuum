"""Long-running Antigravity SDK observer.

Streams total_usage deltas + active-conversation metadata over stdio
JSON-lines so the Mac daemon's AntigravitySidecarObserver.swift can
swap the AntigravityObservation.sdk implementation in for the disk
parser.

Spawned by main.py when the agent header is `{"agent": "observer"}`.
Loops until stdin closes (Swift terminates the process on toggle OFF
or on disable-during-shutdown).

Protocol — every line of stdout is a JSON object:
  {"type": "ready"}                    after Connection bootstrap
  {"type": "conversations", "items": [{uuid, project_title, cwd, model}]}
  {"type": "usage", "uuid": "...", "totals": {input, output, cached, total}}
  {"type": "error", "msg": "..."}      non-fatal observer error
  {"type": "shutdown"}                  emitted right before exit

Notes:
- v0.7.15 ships the minimal viable: list_conversations() once at
  startup + poll active conversation total_usage every 2s. Streaming
  via SDK callbacks is a v0.8 follow-up if google-antigravity surfaces
  a subscribe-style API.
- Errors during polling are emitted as `{"type":"error"}` lines so the
  Mac side can show a soft banner — we don't tear the observer down.
"""

from __future__ import annotations

import json
import sys
import time
import traceback
from typing import Any


def emit(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj))
    sys.stdout.write("\n")
    sys.stdout.flush()


def main(initial_cmd: dict[str, Any]) -> int:
    """Entry point invoked from main.py. `initial_cmd` is the first
    stdin line that selected this agent. Returns process exit code."""
    _ = initial_cmd  # reserved for future options (e.g. poll interval)

    try:
        from google.antigravity import Connection  # type: ignore[import-not-found]
    except ImportError as exc:
        emit({"type": "error", "code": "sdk_import_failed", "msg": str(exc)})
        return 1

    # Bootstrap the SDK connection. Connection.local() reads the
    # CSRF token + port from ~/.gemini/antigravity/logs/<TS>/ls-main.log
    # if Antigravity is running; otherwise raises.
    try:
        conn = Connection.local()
    except Exception as exc:  # noqa: BLE001
        emit({
            "type": "error",
            "code": "connection_failed",
            "msg": f"{type(exc).__name__}: {exc}",
            "hint": "Antigravity.app may not be running. Launch it and re-enable SDK mode.",
        })
        return 1

    emit({"type": "ready", "version": "0.7.15"})

    import select

    def _emit_exc(code: str, exc: BaseException) -> None:
        # Audit P1 fix: every exception path emits both the type/message
        # and a short traceback so the Mac app can distinguish "SDK
        # offline" from "permissions issue" from "regression in our
        # parsing". Previously some sites preserved the trace and others
        # didn't — the inconsistency was unhelpful.
        emit({
            "type": "error",
            "code": code,
            "msg": f"{type(exc).__name__}: {exc}",
            "trace": traceback.format_exc(limit=2),
        })

    # Initial inventory.
    try:
        convos = list(conn.list_conversations())
        emit({
            "type": "conversations",
            "items": [
                {
                    "uuid": getattr(c, "uuid", None),
                    "project_title": getattr(c, "project_title", None),
                    "cwd": getattr(c, "cwd", None),
                    "model": getattr(c, "model", None),
                }
                for c in convos
            ],
        })
    except Exception as exc:  # noqa: BLE001
        _emit_exc("list_conversations_failed", exc)

    # Polling loop — emit total_usage deltas every 2s. Watches stdin
    # closing as the shutdown signal (Swift closes when toggle goes OFF).
    #
    # Audit P1 fix: previous loop did `select(..., timeout=0)` then
    # `time.sleep(2.0)`, which (a) made the select pointless and
    # (b) made shutdown latency 2s after stdin close. Folding the wait
    # into select gives near-instant shutdown and halves wake-ups.
    last_totals: dict[str, dict[str, int]] = {}
    POLL_INTERVAL = 2.0
    while True:
        try:
            ready, _, _ = select.select([sys.stdin], [], [], POLL_INTERVAL)
            if ready:
                line = sys.stdin.readline()
                if not line:
                    break  # stdin closed → shutdown
                emit({"type": "log", "msg": f"control: {line.strip()!r}"})
        except (KeyboardInterrupt, SystemExit):
            raise
        except Exception as exc:  # noqa: BLE001
            _emit_exc("stdin_select_failed", exc)

        try:
            for c in conn.list_conversations():
                uuid = getattr(c, "uuid", None)
                if not uuid:
                    continue
                usage = getattr(c, "total_usage", None)
                if usage is None:
                    continue
                # Audit P2 fix: explicit attribute presence check instead
                # of silently defaulting to 0. If the SDK API renames
                # a field, we want a loud error (once) rather than the
                # quiet "user used 0 tokens" lie.
                missing = [
                    name for name in
                    ("prompt_tokens", "candidate_tokens", "cached_tokens", "thoughts_tokens")
                    if not hasattr(usage, name)
                ]
                if missing:
                    emit({
                        "type": "error",
                        "code": "sdk_usage_schema_mismatch",
                        "missing_attrs": missing,
                        "uuid": uuid,
                    })
                    continue
                totals = {
                    "input": int(getattr(usage, "prompt_tokens", 0) or 0),
                    "output": int(getattr(usage, "candidate_tokens", 0) or 0),
                    "cached": int(getattr(usage, "cached_tokens", 0) or 0),
                    "thoughts": int(getattr(usage, "thoughts_tokens", 0) or 0),
                }
                totals["total"] = (
                    totals["input"] + totals["output"]
                    + totals["cached"] + totals["thoughts"]
                )
                if last_totals.get(uuid) != totals:
                    last_totals[uuid] = totals
                    emit({"type": "usage", "uuid": uuid, "totals": totals})
        except (KeyboardInterrupt, SystemExit):
            raise
        except Exception as exc:  # noqa: BLE001
            _emit_exc("poll_failed", exc)

    emit({"type": "shutdown"})
    return 0
