#!/usr/bin/env bash
# Download FFF macOS assets for Continuum and stage under
# apple/ClawdmeterMac/Resources/Vendor/fff/:
#   - libfff_c.dylib — Code tab repo file search (Cmd+P + @-mention)
#   - fff-mcp — bundled MCP server for Claude + Codex agent search tools
#
# FFF keeps a warm in-process index — dramatically faster than forking
# `git ls-files` + Swift fuzzy matching on every keystroke.
#
# Strategy:
#   1. Download c-lib-<arch>-apple-darwin.dylib from dmtrKovalenko/fff releases
#   2. SHA-256 verify against the published sibling .sha256 file
#   3. Stage libfff_c.dylib + fff-mcp under Vendor/fff/
#
# Skip when the bundled dylib already exists and matches the pinned
# version. Skippable via CLAWDMETER_SKIP_BUNDLED_FFF=1 for dev iteration.
#
# Pinned to fff v0.9.4. Bump FFF_VERSION and the arch SHA pins together.

set -euo pipefail

FFF_VERSION="0.9.4"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/apple/ClawdmeterMac/Resources/Vendor/fff"
TMP_DIR="$(mktemp -d -t clawdmeter-fff-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)
    FFF_ASSET="c-lib-aarch64-apple-darwin.dylib"
    FFF_MCP_ASSET="fff-mcp-aarch64-apple-darwin"
    ;;
  x86_64)
    FFF_ASSET="c-lib-x86_64-apple-darwin.dylib"
    FFF_MCP_ASSET="fff-mcp-x86_64-apple-darwin"
    ;;
  *)
    echo "✗ Unsupported macOS architecture for bundled FFF: $ARCH" >&2
    exit 1
    ;;
esac

mkdir -p "$VENDOR_DIR"
echo "→ Bundled FFF target: $VENDOR_DIR (fff $FFF_VERSION, $ARCH)"

VERSION_FILE="$VENDOR_DIR/.bundled-version"
if [[ -f "$VERSION_FILE" ]] \
  && [[ "$(cat "$VERSION_FILE")" == "$FFF_VERSION" ]] \
  && [[ -f "$VENDOR_DIR/libfff_c.dylib" ]] \
  && [[ -x "$VENDOR_DIR/fff-mcp" ]]; then
  echo "→ Already at $FFF_VERSION; skipping download. (Force re-download: rm $VERSION_FILE)"
  exit 0
fi

BASE_URL="https://github.com/dmtrKovalenko/fff/releases/download/v${FFF_VERSION}"
DYLIB_URL="$BASE_URL/$FFF_ASSET"
SHA_URL="$BASE_URL/${FFF_ASSET}.sha256"

if command -v shasum >/dev/null 2>&1; then
  SHASUM_CMD=(shasum -a 256)
else
  SHASUM_CMD=(sha256sum)
fi

echo "→ Fetching $FFF_ASSET"
curl -fSL "$DYLIB_URL" -o "$TMP_DIR/libfff_c.dylib"
curl -fSL "$SHA_URL" -o "$TMP_DIR/libfff_c.dylib.sha256"

echo "→ Verifying SHA-256"
EXPECTED_SHA="$(awk '{print $1}' "$TMP_DIR/libfff_c.dylib.sha256")"
ACTUAL_SHA=$("${SHASUM_CMD[@]}" "$TMP_DIR/libfff_c.dylib" | awk '{print $1}')
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  echo "✗ SHA-256 mismatch for $FFF_ASSET" >&2
  echo "  expected: $EXPECTED_SHA" >&2
  echo "  got:      $ACTUAL_SHA" >&2
  exit 1
fi
echo "→ SHA-256 OK"

install -m 644 "$TMP_DIR/libfff_c.dylib" "$VENDOR_DIR/libfff_c.dylib"
echo "→ Staged $VENDOR_DIR/libfff_c.dylib"

MCP_URL="$BASE_URL/$FFF_MCP_ASSET"
MCP_SHA_URL="$BASE_URL/${FFF_MCP_ASSET}.sha256"
echo "→ Fetching $FFF_MCP_ASSET"
curl -fSL "$MCP_URL" -o "$TMP_DIR/fff-mcp"
curl -fSL "$MCP_SHA_URL" -o "$TMP_DIR/fff-mcp.sha256"
EXPECTED_MCP_SHA="$(awk '{print $1}' "$TMP_DIR/fff-mcp.sha256")"
ACTUAL_MCP_SHA=$("${SHASUM_CMD[@]}" "$TMP_DIR/fff-mcp" | awk '{print $1}')
if [[ "$ACTUAL_MCP_SHA" != "$EXPECTED_MCP_SHA" ]]; then
  echo "✗ SHA-256 mismatch for $FFF_MCP_ASSET" >&2
  echo "  expected: $EXPECTED_MCP_SHA" >&2
  echo "  got:      $ACTUAL_MCP_SHA" >&2
  exit 1
fi
install -m 755 "$TMP_DIR/fff-mcp" "$VENDOR_DIR/fff-mcp"
echo "→ Staged $VENDOR_DIR/fff-mcp"

echo "$FFF_VERSION" > "$VERSION_FILE"
