#!/usr/bin/env python3
"""Sidecar dispatcher for Clawdmeter SDK mode.

Spawned by `AntigravitySidecarManager.swift` when the user toggles SDK
mode ON. Receives the agent name on stdin's first JSON line, then
forwards subsequent lines to the chosen module.

v0.7.15 — real SDK probe:
- Emit `{type:"ready", sdk_import_ok:bool, version:"0.7.15"}` as the
  first line so the Swift probe can immediately see whether the venv
  has `google-antigravity` installed and importable.
- On `agent:"probe"`: exit cleanly after the ready line.
- On `agent:"observer"`: hand off to observer.main(), which keeps the
  process alive streaming SDK events.
- On other / unknown agents: emit a clear sdk_not_provisioned-ish
  error message and exit.

Failure modes:
- `import google.antigravity` raises → first line carries
  `{sdk_import_ok:false}`, second line carries
  `{type:"error", code:"sdk_import_failed", msg:"<exc>"}`. Sidecar
  exits 1.
- Header line is missing or unparseable → emit
  `{type:"error", code:"bad_header"}` and exit 1.
"""

from __future__ import annotations

import json
import sys
import traceback
from typing import Any


def emit(obj: dict[str, Any]) -> None:
    """Write one JSON-line to stdout + flush."""
    sys.stdout.write(json.dumps(obj))
    sys.stdout.write("\n")
    sys.stdout.flush()


def main() -> int:
    # Step 1: try to import the SDK. The result determines whether the
    # ready line announces sdk_import_ok=true or false. Swift's
    # AntigravitySidecarManager.probeSidecar reads this directly.
    sdk_import_ok = False
    import_err: str | None = None
    try:
        import google.antigravity  # type: ignore[import-not-found]  # noqa: F401
        sdk_import_ok = True
    except ImportError as exc:
        import_err = f"{type(exc).__name__}: {exc}"
    except Exception as exc:  # broader catch — google-antigravity may
        # raise non-ImportError exceptions during top-level init (e.g.
        # network failures during package metadata fetch). Still treat
        # as "not provisioned" rather than crashing.
        import_err = f"{type(exc).__name__}: {exc}"

    emit({
        "type": "ready",
        "version": "0.7.15",
        "sdk_import_ok": sdk_import_ok,
    })

    if not sdk_import_ok:
        emit({
            "type": "error",
            "code": "sdk_import_failed",
            "msg": import_err or "google.antigravity import failed",
        })
        return 1

    # Step 2: read the agent header.
    try:
        header = sys.stdin.readline()
        if not header:
            emit({"type": "error", "code": "bad_header", "msg": "no header line received"})
            return 1
        cmd = json.loads(header)
    except json.JSONDecodeError as exc:
        emit({"type": "error", "code": "bad_header", "msg": f"bad header JSON: {exc}"})
        return 1

    agent = cmd.get("agent")

    # Step 3: dispatch.
    if agent == "probe":
        # Smoke test — already emitted ready above, just exit cleanly.
        emit({"type": "result", "data": {"probe": "ok"}})
        return 0

    if agent == "observer":
        try:
            import observer  # local sibling module
            return observer.main(cmd)
        except Exception as exc:  # noqa: BLE001
            emit({
                "type": "error",
                "code": "observer_failed",
                "msg": f"{type(exc).__name__}: {exc}",
                "trace": traceback.format_exc(limit=3),
            })
            return 1

    emit({
        "type": "error",
        "code": "unknown_agent",
        "msg": f"unknown agent: {agent!r}",
    })
    return 1


if __name__ == "__main__":
    sys.exit(main())
