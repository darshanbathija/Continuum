"""SDK-mode observer. Long-running stdio JSON-lines bridge between the
Mac daemon's AntigravitySidecarObserver.swift and the running
Antigravity language_server via `Connection.local()`.

v0.6.0 ships a skeleton. Real implementation requires:
    pip install google-antigravity~=0.0.3

And the live `language_server` running. v0.6.1 fills in:
    from google.antigravity import Connection
    conn = Connection.local()
    for conversation in conn.list_conversations():
        emit({"type": "conversation", "uuid": conversation.uuid, ...})
        for delta in conversation.subscribe_total_usage():
            emit({"type": "total_usage_delta", "delta": delta._asdict()})

For now: receive cmd lines from stdin, respond with the same
`sdk_not_provisioned` error so the daemon's fail-soft path exercises.
"""

from __future__ import annotations

import json
import sys


def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj))
    sys.stdout.write("\n")
    sys.stdout.flush()


def main() -> int:
    emit({"type": "ready", "agent": "observer"})
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            cmd = json.loads(raw)
        except json.JSONDecodeError:
            emit({"type": "error", "msg": "bad JSON", "raw": raw[:200]})
            continue
        op = cmd.get("op", "")
        # v0.6.1 will route these to google.antigravity.Connection calls.
        emit({
            "type": "error",
            "code": "sdk_not_provisioned",
            "msg": "SDK mode skeleton — toggle off in Settings.",
            "echoed_op": op,
        })
    return 0


if __name__ == "__main__":
    sys.exit(main())
