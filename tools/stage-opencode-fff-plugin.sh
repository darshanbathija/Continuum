#!/usr/bin/env bash
# Stage the opencode-fff-search plugin for Continuum's managed OpenCode
# runtime. Bundles opencode.json + npm dependencies so `opencode serve`
# can override grep/glob with FFF without a runtime network fetch.
#
# Output: apple/ClawdmeterMac/Resources/Vendor/opencode-fff/config/
#   opencode.json      — {"plugin":["opencode-fff-search"]}
#   package.json       — copied from the committed tools/opencode-fff/ source
#   package-lock.json  — copied from the committed source (integrity-locked)
#   node_modules/      — installed via `npm ci` against the committed lockfile
#
# Supply-chain note: the dependency set is pinned by the COMMITTED lockfile at
# tools/opencode-fff/package-lock.json (with per-package integrity hashes), and
# installed with `npm ci`, which refuses to run if package.json and the lock
# disagree and never silently resolves a newer/tampered version. To change the
# plugin version, edit tools/opencode-fff/package.json and regenerate the lock
# (`npm install --package-lock-only --omit=dev` in that dir) — do NOT hand-edit
# the staged copies here.
#
# Requires bundled Node (tools/download-bundled-node.sh). Skippable via
# CLAWDMETER_SKIP_OPENCODE_FFF_PLUGIN=1 for dev iteration.

set -euo pipefail

OPENCODE_FFF_PLUGIN_VERSION="0.7.0"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/apple/ClawdmeterMac/Resources/Vendor/opencode-fff"
CONFIG_DIR="$VENDOR_DIR/config"
# Committed package.json + package-lock.json source — the supply-chain anchor
# that `npm ci` enforces against.
PKG_SRC_DIR="$REPO_ROOT/tools/opencode-fff"
NODE_BIN="$REPO_ROOT/apple/ClawdmeterMac/Resources/Vendor/node/bin/node"
NPM_BIN="$REPO_ROOT/apple/ClawdmeterMac/Resources/Vendor/node/bin/npm"
VERSION_FILE="$VENDOR_DIR/.bundled-version"

if [[ "${CLAWDMETER_SKIP_OPENCODE_FFF_PLUGIN:-0}" = "1" ]]; then
  echo "→ Skipping opencode-fff plugin staging (CLAWDMETER_SKIP_OPENCODE_FFF_PLUGIN=1)"
  exit 0
fi

mkdir -p "$CONFIG_DIR"
echo "→ OpenCode FFF plugin target: $CONFIG_DIR (opencode-fff-search $OPENCODE_FFF_PLUGIN_VERSION)"

if [[ -f "$VERSION_FILE" ]] \
  && [[ "$(cat "$VERSION_FILE")" == "$OPENCODE_FFF_PLUGIN_VERSION" ]] \
  && [[ -f "$CONFIG_DIR/opencode.json" ]] \
  && [[ -d "$CONFIG_DIR/node_modules/opencode-fff-search" ]]; then
  echo "→ Already at $OPENCODE_FFF_PLUGIN_VERSION; skipping staging."
  exit 0
fi

if [[ ! -x "$NODE_BIN" ]] || [[ ! -x "$NPM_BIN" ]]; then
  echo "✗ Bundled Node/npm not found at $NODE_BIN — run tools/download-bundled-node.sh first" >&2
  exit 1
fi

if [[ ! -f "$PKG_SRC_DIR/package.json" ]] || [[ ! -f "$PKG_SRC_DIR/package-lock.json" ]]; then
  echo "✗ Committed package.json/package-lock.json not found in $PKG_SRC_DIR" >&2
  echo "  These are the supply-chain lock source and must be committed." >&2
  exit 1
fi

cat > "$CONFIG_DIR/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "plugin": ["opencode-fff-search"]
}
EOF

# Stage the COMMITTED, integrity-locked package.json + lockfile (never an
# ad-hoc generated one) so `npm ci` installs the exact pinned dependency tree.
cp "$PKG_SRC_DIR/package.json" "$CONFIG_DIR/package.json"
cp "$PKG_SRC_DIR/package-lock.json" "$CONFIG_DIR/package-lock.json"

# `npm ci` REQUIRES the lockfile and fails on any package.json/lock drift —
# unlike `npm install`, it never resolves or writes a newer version, so a
# tampered registry response or a stale lock can't slip a different build in.
echo "→ npm ci --omit=dev (locked to committed package-lock.json)"
(
  cd "$CONFIG_DIR"
  PATH="$(dirname "$NODE_BIN"):$PATH" "$NPM_BIN" ci --omit=dev --no-fund --no-audit
)

if [[ ! -f "$CONFIG_DIR/node_modules/opencode-fff-search/index.js" ]]; then
  echo "✗ opencode-fff-search install did not produce index.js" >&2
  exit 1
fi

echo "$OPENCODE_FFF_PLUGIN_VERSION" > "$VERSION_FILE"
echo "→ Staged OpenCode FFF plugin config at $CONFIG_DIR"
