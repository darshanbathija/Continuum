#!/usr/bin/env bash
# Stage the opencode-fff-search plugin for Continuum's managed OpenCode
# runtime. Bundles opencode.json + npm dependencies so `opencode serve`
# can override grep/glob with FFF without a runtime network fetch.
#
# Output: apple/ClawdmeterMac/Resources/Vendor/opencode-fff/config/
#   opencode.json   — {"plugin":["opencode-fff-search"]}
#   package.json    — pins opencode-fff-search
#   node_modules/   — installed via bundled npm
#
# Requires bundled Node (tools/download-bundled-node.sh). Skippable via
# CLAWDMETER_SKIP_OPENCODE_FFF_PLUGIN=1 for dev iteration.

set -euo pipefail

OPENCODE_FFF_PLUGIN_VERSION="0.7.0"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/apple/ClawdmeterMac/Resources/Vendor/opencode-fff"
CONFIG_DIR="$VENDOR_DIR/config"
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

cat > "$CONFIG_DIR/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "plugin": ["opencode-fff-search"]
}
EOF

cat > "$CONFIG_DIR/package.json" <<EOF
{
  "private": true,
  "dependencies": {
    "opencode-fff-search": "${OPENCODE_FFF_PLUGIN_VERSION}"
  }
}
EOF

echo "→ npm install opencode-fff-search@${OPENCODE_FFF_PLUGIN_VERSION}"
(
  cd "$CONFIG_DIR"
  PATH="$(dirname "$NODE_BIN"):$PATH" "$NPM_BIN" install --omit=dev --no-fund --no-audit
)

if [[ ! -f "$CONFIG_DIR/node_modules/opencode-fff-search/index.js" ]]; then
  echo "✗ opencode-fff-search install did not produce index.js" >&2
  exit 1
fi

echo "$OPENCODE_FFF_PLUGIN_VERSION" > "$VERSION_FILE"
echo "→ Staged OpenCode FFF plugin config at $CONFIG_DIR"
