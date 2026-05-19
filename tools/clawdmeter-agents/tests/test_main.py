"""Smoke tests for the v0.6.0 sidecar skeleton. Real-impl tests land in v0.6.1."""

import io
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parent.parent


def test_main_emits_ready_then_error_when_no_provisioning():
    """The skeleton outputs `ready` then a `sdk_not_provisioned` error."""
    proc = subprocess.run(
        [sys.executable, str(ROOT / "main.py")],
        input=json.dumps({"agent": "observer"}) + "\n",
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert proc.returncode == 0, proc.stderr
    lines = [line for line in proc.stdout.strip().split("\n") if line]
    assert len(lines) >= 2

    ready = json.loads(lines[0])
    assert ready["type"] == "ready"
    assert ready["version"] == "0.6.0-skeleton"

    err = json.loads(lines[1])
    assert err["type"] == "error"
    assert err["code"] == "sdk_not_provisioned"
    assert err["agent"] == "observer"


def test_main_handles_missing_header():
    """No stdin → emit error, exit non-zero."""
    proc = subprocess.run(
        [sys.executable, str(ROOT / "main.py")],
        input="",
        capture_output=True,
        text=True,
        timeout=10,
    )
    # Exit code 1 is expected for the no-header case.
    assert proc.returncode == 1
    lines = [line for line in proc.stdout.strip().split("\n") if line]
    assert any(json.loads(l).get("type") == "error" for l in lines)


def test_main_handles_garbage_header():
    """Bad JSON header → emit error, exit non-zero."""
    proc = subprocess.run(
        [sys.executable, str(ROOT / "main.py")],
        input="this is not json\n",
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert proc.returncode == 1
    lines = [line for line in proc.stdout.strip().split("\n") if line]
    # First line is "ready", then "bad header JSON" error.
    assert lines[0]
    err = json.loads(lines[-1])
    assert err["type"] == "error"
    assert "JSON" in err["msg"]
