#!/usr/bin/env bash
# Download `opencode` (sst/opencode AI agent CLI) for macOS arm64 and
# stage under apple/ClawdmeterMac/Resources/Vendor/opencode/. The Mac app
# bundles this so OpencodeProcessManager.locateBinary() can fall back to
# a baked-in binary when the user doesn't have opencode on PATH —
# zero-Terminal install + auth flow under Settings → Providers.
#
# `opencode` is a single Bun-bundled binary that exposes:
#   - `opencode serve` — long-running HTTP+SSE server we consume for
#     usage events + chat streaming
#   - `opencode auth login/logout/list` — TUI auth flow we host in an
#     embedded SwiftTerm terminal sheet
#   - `opencode run` — one-shot prompt execution used by the diagnostic
#     command in Settings
#
# Strategy:
#   1. Download opencode-darwin-arm64.zip from anomalyco/opencode releases
#      (the project moved orgs from sst/ → anomalyco/ in 2025; verified
#      via gh release view 2026-05-23).
#   2. SHA-256 verify against a pinned digest (no sibling .sha256 file
#      is published, so we pin inline).
#   3. unzip
#   4. Stage at apple/ClawdmeterMac/Resources/Vendor/opencode/opencode
#
# Skip when the bundled binary already exists and matches the pinned
# version. Skippable via CLAWDMETER_SKIP_BUNDLED_OPENCODE=1 for dev
# iteration (falls back to PATH lookup at runtime).
#
# Pinned to opencode 1.15.7 (released 2026-05-21). Bump OPENCODE_VERSION
# AND OPENCODE_SHA256 together below to pull a newer release.

set -euo pipefail

OPENCODE_VERSION="1.15.7"
# SHA-256 of opencode-darwin-arm64.zip @ v1.15.7. Read from GitHub's
# asset metadata via `gh release view`. Update this in lockstep with
# OPENCODE_VERSION above.
OPENCODE_SHA256="335307ee87d3dac84986bf8f0bd4273a43c35fcb9b124556c2f4fad4a510e3a4"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/apple/ClawdmeterMac/Resources/Vendor/opencode"
TMP_DIR="$(mktemp -d -t clawdmeter-opencode-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$VENDOR_DIR"
echo "→ Bundled opencode target: $VENDOR_DIR (opencode $OPENCODE_VERSION)"

VERSION_FILE="$VENDOR_DIR/.bundled-version"
if [[ -f "$VERSION_FILE" ]] && [[ "$(cat "$VERSION_FILE")" == "$OPENCODE_VERSION" ]] && [[ -x "$VENDOR_DIR/opencode" ]]; then
  echo "→ Already at $OPENCODE_VERSION; skipping download. (Force re-download: rm $VERSION_FILE)"
  exit 0
fi

ZIPFILE="opencode-darwin-arm64.zip"
URL="https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${ZIPFILE}"

# Pick a shasum frontend. macOS ships `shasum`, Linux usually `sha256sum`.
if command -v shasum >/dev/null 2>&1; then
  SHASUM_CMD=(shasum -a 256)
else
  SHASUM_CMD=(sha256sum)
fi

echo "→ Fetching $ZIPFILE"
curl -fSL "$URL" -o "$TMP_DIR/$ZIPFILE"

echo "→ Verifying SHA-256 (pinned: ${OPENCODE_SHA256:0:16}…)"
ACTUAL_SHA=$("${SHASUM_CMD[@]}" < "$TMP_DIR/$ZIPFILE" | awk '{print $1}')
if [[ "$ACTUAL_SHA" != "$OPENCODE_SHA256" ]]; then
  echo "✗ SHA-256 mismatch for $ZIPFILE" >&2
  echo "  expected: $OPENCODE_SHA256" >&2
  echo "  got:      $ACTUAL_SHA" >&2
  echo "  Either the upstream asset was tampered with, OR the pin in this" >&2
  echo "  script is stale. Verify via:" >&2
  echo "    gh release view v${OPENCODE_VERSION} --repo anomalyco/opencode --json assets" >&2
  exit 1
fi
echo "→ SHA-256 OK"

echo "→ Extracting"
unzip -q -o "$TMP_DIR/$ZIPFILE" -d "$TMP_DIR/extract"

# Locate the opencode binary inside the extracted directory. The zip
# layout has historically been `opencode-darwin-arm64/opencode` but we
# search defensively in case it ever flattens.
SRC=""
if [[ -x "$TMP_DIR/extract/opencode-darwin-arm64/opencode" ]]; then
  SRC="$TMP_DIR/extract/opencode-darwin-arm64/opencode"
elif [[ -x "$TMP_DIR/extract/opencode" ]]; then
  SRC="$TMP_DIR/extract/opencode"
else
  SRC=$(find "$TMP_DIR/extract" -name opencode -type f -perm -u+x | head -n1)
fi

if [[ -z "$SRC" || ! -x "$SRC" ]]; then
  echo "✗ Expected opencode binary, not found in extracted zip" >&2
  ls -laR "$TMP_DIR/extract/" >&2 || true
  exit 1
fi

cp "$SRC" "$VENDOR_DIR/opencode"
chmod +x "$VENDOR_DIR/opencode"
echo "$OPENCODE_VERSION" > "$VERSION_FILE"

echo "→ Verifying"
"$VENDOR_DIR/opencode" --version

echo "✓ Bundled opencode $OPENCODE_VERSION at $VENDOR_DIR/opencode ($(du -sh "$VENDOR_DIR/opencode" | cut -f1))"
