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
#   2. SHA-256 verify against a HARD-PINNED constant baked into this script
#      (NOT against a sibling .sha256 fetched from the same release — a
#      tampered release would simply ship a matching hash, defeating the
#      check. Pinning the hash here moves trust into version control.)
#   3. Stage libfff_c.dylib + fff-mcp under Vendor/fff/
#
# Skip when the bundled dylib already exists and matches the pinned
# version. Skippable via CLAWDMETER_SKIP_BUNDLED_FFF=1 for dev iteration.
#
# Pinned to fff v0.9.4. Bump FFF_VERSION and the pinned_sha256 values together.

set -euo pipefail

FFF_VERSION="0.9.4"

# Hard-pinned SHA-256 for every bundled asset. These are the supply-chain
# trust anchor: the build fails if a downloaded asset does not match its pin,
# regardless of what the release ships. (macOS system bash is 3.2, which has
# no associative arrays, so the pins live in a case statement keyed by asset
# name rather than a `declare -A` map.)
#
# IMPORTANT: these pins are for the CURRENT FFF_VERSION above. When bumping
# FFF_VERSION, re-compute all four with:
#   curl -fsSL <release-url>/<asset> | shasum -a 256
# and replace the values below.
pinned_sha256() {
  case "$1" in
    c-lib-aarch64-apple-darwin.dylib) echo "7e371b5d655e6737ed24147cdcb477ab6e362b338de9b0f7aaf785b6636fa6cd" ;;
    c-lib-x86_64-apple-darwin.dylib)  echo "7d58ec589cbd054387496755651e0700412d7789bed4070c0617ff40f61acced" ;;
    fff-mcp-aarch64-apple-darwin)     echo "90a7007d378583531cb3ca03037303ce0bd1ec7b31ca86a5b90d5683440df5b3" ;;
    fff-mcp-x86_64-apple-darwin)      echo "20a91c0421ac05b9d32f0349ff147e5d0ad118ce6cd8a831ba9a873d98676cfd" ;;
    *) echo "" ;;
  esac
}

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

if command -v shasum >/dev/null 2>&1; then
  SHASUM_CMD=(shasum -a 256)
else
  SHASUM_CMD=(sha256sum)
fi

# Verify a staged file against its hard-pinned SHA-256. Exits non-zero on
# a missing pin or a mismatch.
verify_pinned_sha() {
  local asset="$1" file="$2"
  local expected
  expected="$(pinned_sha256 "$asset")"
  if [[ -z "$expected" ]]; then
    echo "✗ No pinned SHA-256 for $asset — refusing to bundle an unpinned asset." >&2
    echo "  Add its hash to pinned_sha256() in $(basename "$0")." >&2
    exit 1
  fi
  local actual
  actual=$("${SHASUM_CMD[@]}" "$file" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    echo "✗ SHA-256 mismatch for $asset" >&2
    echo "  expected (pinned): $expected" >&2
    echo "  got:               $actual" >&2
    exit 1
  fi
  echo "→ SHA-256 OK ($asset)"
}

echo "→ Fetching $FFF_ASSET"
curl -fSL "$DYLIB_URL" -o "$TMP_DIR/libfff_c.dylib"

echo "→ Verifying SHA-256 against pin"
verify_pinned_sha "$FFF_ASSET" "$TMP_DIR/libfff_c.dylib"

install -m 644 "$TMP_DIR/libfff_c.dylib" "$VENDOR_DIR/libfff_c.dylib"
echo "→ Staged $VENDOR_DIR/libfff_c.dylib"

MCP_URL="$BASE_URL/$FFF_MCP_ASSET"
echo "→ Fetching $FFF_MCP_ASSET"
curl -fSL "$MCP_URL" -o "$TMP_DIR/fff-mcp"

echo "→ Verifying SHA-256 against pin"
verify_pinned_sha "$FFF_MCP_ASSET" "$TMP_DIR/fff-mcp"

install -m 755 "$TMP_DIR/fff-mcp" "$VENDOR_DIR/fff-mcp"
echo "→ Staged $VENDOR_DIR/fff-mcp"

echo "$FFF_VERSION" > "$VERSION_FILE"
