"""Smoke tests for the v0.7.15 sidecar dispatcher.

These run without `google-antigravity` installed, exercising the
sdk_import_failed path. The dispatcher emits one `ready` line with
`sdk_import_ok: false`, then a `sdk_import_failed` error, then exits 1.
"""

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent


def test_main_emits_ready_then_sdk_import_failed_without_sdk():
    """Without google-antigravity available, the dispatcher should emit
    `ready` with `sdk_import_ok:false`, then a `sdk_import_failed` error,
    and exit 1 (so AntigravitySidecarManager can revert the toggle)."""
    proc = subprocess.run(
        [sys.executable, str(ROOT / "main.py")],
        input=json.dumps({"agent": "observer"}) + "\n",
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert proc.returncode == 1, proc.stderr
    lines = [line for line in proc.stdout.strip().split("\n") if line]
    assert len(lines) >= 2

    ready = json.loads(lines[0])
    assert ready["type"] == "ready"
    assert ready["sdk_import_ok"] is False

    err = json.loads(lines[1])
    assert err["type"] == "error"
    assert err["code"] == "sdk_import_failed"
    # Audit P1 fix: traceback is now preserved so support can
    # distinguish "package missing" from "permission denied".
    assert "trace" in err


def test_main_handles_missing_header_when_sdk_missing():
    """No stdin → emit error, exit non-zero. Without SDK, the dispatcher
    fails on import before it even tries to read a header."""
    proc = subprocess.run(
        [sys.executable, str(ROOT / "main.py")],
        input="",
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert proc.returncode == 1
    lines = [line for line in proc.stdout.strip().split("\n") if line]
    assert any(json.loads(l).get("type") == "error" for l in lines)


def test_main_handles_garbage_header_when_sdk_missing():
    """Bad JSON header reaches the dispatcher only when the SDK is
    importable. Without it, we never get past the import-failed exit,
    so this test asserts the import-failed shape rather than the
    header parser shape."""
    proc = subprocess.run(
        [sys.executable, str(ROOT / "main.py")],
        input="this is not json\n",
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert proc.returncode == 1
    lines = [line for line in proc.stdout.strip().split("\n") if line]
    err = json.loads(lines[-1])
    assert err["type"] == "error"
    # In a no-SDK environment the dispatcher emits sdk_import_failed; in
    # an SDK-equipped environment it would emit bad_header. Accept both.
    assert err["code"] in ("sdk_import_failed", "bad_header")
