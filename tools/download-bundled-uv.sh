#!/usr/bin/env bash
# Download `uv` (Astral's Python package manager) for macOS arm64 and
# stage under apple/ClawdmeterMac/Resources/Vendor/uv/. The Mac app
# bundles this so AntigravitySidecarManager.locateUV() can provision
# a sealed Python venv without relying on system Python / pip / brew.
#
# uv handles the whole Python toolchain itself (downloads Python 3.13
# on demand, manages the venv, runs pip-equivalent installs) — single
# static Mach-O binary, ~35MB, signs cleanly. Way simpler than asking
# users to have Python 3.13 + pip on PATH.
#
# Strategy:
#   1. Download uv-aarch64-apple-darwin.tar.gz from GitHub releases
#   2. Extract
#   3. Stage at apple/ClawdmeterMac/Resources/Vendor/uv/uv
#
# Skip when the bundled binary already exists and matches the pinned
# version — re-running is cheap.
#
# Pinned to uv 0.5.11 (released 2026-04-30, stable in the 0.5.x line).
# Bump UV_VERSION below to pull a newer release.

set -euo pipefail

UV_VERSION="0.5.11"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/apple/ClawdmeterMac/Resources/Vendor/uv"
TMP_DIR="$(mktemp -d -t clawdmeter-uv-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$VENDOR_DIR"
echo "→ Bundled uv target: $VENDOR_DIR (uv $UV_VERSION)"

VERSION_FILE="$VENDOR_DIR/.bundled-version"
if [[ -f "$VERSION_FILE" ]] && [[ "$(cat "$VERSION_FILE")" == "$UV_VERSION" ]] && [[ -x "$VENDOR_DIR/uv" ]]; then
  echo "→ Already at $UV_VERSION; skipping download. (Force re-download: rm $VERSION_FILE)"
  exit 0
fi

TARBALL="uv-aarch64-apple-darwin.tar.gz"
URL="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${TARBALL}"

# Pick a shasum frontend. Prefer `shasum`, then fall back to `sha256sum`.
if command -v shasum >/dev/null 2>&1; then
  SHASUM_CHECK=(shasum -a 256 -c -)
else
  SHASUM_CHECK=(sha256sum -c -)
fi

echo "→ Fetching $TARBALL"
curl -fSL "$URL" -o "$TMP_DIR/$TARBALL"

# Astral publishes a sibling `.sha256` for every release asset. Verifying
# closes the supply-chain hole where a MITM or compromised mirror could
# substitute a trojaned uv into our DMG.
echo "→ Fetching ${TARBALL}.sha256"
curl -fSL "${URL}.sha256" -o "$TMP_DIR/${TARBALL}.sha256"
echo "→ Verifying SHA256 of $TARBALL"
(cd "$TMP_DIR" && "${SHASUM_CHECK[@]}" < "${TARBALL}.sha256") \
  || { echo "✗ SHA256 verification FAILED for $TARBALL — aborting" >&2; exit 1; }

echo "→ Extracting"
tar -xzf "$TMP_DIR/$TARBALL" -C "$TMP_DIR"

# The tarball extracts to `uv-aarch64-apple-darwin/uv` (a single binary).
SRC="$TMP_DIR/uv-aarch64-apple-darwin/uv"
if [[ ! -x "$SRC" ]]; then
  echo "✗ Expected uv binary at $SRC, not found" >&2
  ls -la "$TMP_DIR/uv-aarch64-apple-darwin/" >&2 || true
  exit 1
fi

cp "$SRC" "$VENDOR_DIR/uv"
chmod +x "$VENDOR_DIR/uv"
echo "$UV_VERSION" > "$VERSION_FILE"

echo "→ Verifying"
"$VENDOR_DIR/uv" --version

echo "✓ Bundled uv $UV_VERSION at $VENDOR_DIR/uv ($(du -sh "$VENDOR_DIR/uv" | cut -f1))"
