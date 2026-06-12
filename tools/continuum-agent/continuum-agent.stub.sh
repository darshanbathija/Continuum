#!/usr/bin/env bash
# Legacy fallback when no Linux binary or Go toolchain is available.
set -euo pipefail
echo "continuum-agent stub: install Go or set CONTINUUM_AGENT_BINARY_URL, then re-run install-linux.sh." >&2
echo "Build locally: tools/continuum-agent/build-linux.sh" >&2
exit 1
