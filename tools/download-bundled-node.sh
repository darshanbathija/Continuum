#!/usr/bin/env bash
# Download Node.js LTS binary for macOS and stage under
# apple/ClawdmeterMac/Resources/Vendor/node/ so the Mac app can bundle
# it. CodexSDKManager.locateNode() prefers this bundled binary over
# whatever's on PATH — guarantees the SDK runs against the Node version
# we tested.
#
# The bundled binary is gitignored (.gitignore: ~120MB arm64, ~245MB
# universal). Run this script before `tools/build-mac-dmg.sh` to
# include Node in the DMG; dev iteration without running it falls back
# to system Node via CodexSDKManager.locateNode()'s Homebrew search.
#
# Strategy (default — arm64 only):
#   1. Download node-v<VERSION>-darwin-arm64.tar.gz
#   2. Extract
#   3. Stage under apple/ClawdmeterMac/Resources/Vendor/node/
#   4. Include npm + npx wrappers (CodexSDKManager.locateNpm() prefers
#      the sibling of the bundled node — guarantees the npm version is
#      compatible with the node we shipped).
#
# Optional: `--universal` flag triggers a 2× download + lipo into a
# universal binary (~245MB) for Intel Mac support. Most users are
# arm64 by now (Clawdmeter is macOS 14+) so the default skips this.
#
# Pinned to Node 24.15.0 (Krypton LTS, current as of 2026-05-20).
# Bump VERSION below to pull a newer LTS — and re-test the
# `@openai/codex-sdk` provisioning against it.
#
# Skip the download when the bundled binary already exists and matches
# the pinned version — re-running is cheap.

set -euo pipefail

VERSION="v24.15.0"
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --help|-h) echo "Usage: $0 [--universal]"; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 1 ;;
  esac
done
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/apple/ClawdmeterMac/Resources/Vendor/node"
TMP_DIR="$(mktemp -d -t clawdmeter-node-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "→ Bundled Node target: $VENDOR_DIR (Node $VERSION)"

# Fast path: if the version file matches what we have, skip.
VERSION_FILE="$VENDOR_DIR/.bundled-version"
if [[ -f "$VERSION_FILE" ]] && [[ "$(cat "$VERSION_FILE")" == "$VERSION" ]] && [[ -x "$VENDOR_DIR/bin/node" ]]; then
  echo "→ Already at $VERSION; skipping download. (Force re-download: rm $VERSION_FILE)"
  exit 0
fi

ARM_TARBALL="node-${VERSION}-darwin-arm64.tar.gz"
BASE_URL="https://nodejs.org/dist/${VERSION}"

# Pick a shasum frontend. Prefer `shasum`, then fall back to `sha256sum`.
if command -v shasum >/dev/null 2>&1; then
  SHASUM_CHECK=(shasum -a 256 -c -)
else
  SHASUM_CHECK=(sha256sum -c -)
fi

# Fetch the publisher-signed checksum manifest. Verifying every tarball
# against this manifest closes the supply-chain hole where a MITM (or a
# compromised mirror) could substitute a trojaned Node into our DMG.
#
# Optional: if `gpg` is present and the Node release keys are imported,
# verify the manifest's GPG signature too. We don't fail when gpg is
# missing (build hosts vary), but we ALWAYS fail when the SHA mismatches.
SHASUMS_URL="${BASE_URL}/SHASUMS256.txt"
echo "→ Fetching SHASUMS256.txt"
curl -fsSL "$SHASUMS_URL" -o "$TMP_DIR/SHASUMS256.txt"
if command -v gpg >/dev/null 2>&1 && curl -fsSL "${SHASUMS_URL}.sig" -o "$TMP_DIR/SHASUMS256.txt.sig" 2>/dev/null; then
  if gpg --verify "$TMP_DIR/SHASUMS256.txt.sig" "$TMP_DIR/SHASUMS256.txt" 2>/dev/null; then
    echo "→ SHASUMS256.txt GPG signature verified"
  else
    echo "⚠  GPG signature could not be verified (release keys may not be imported)."
    echo "   Import the keys from https://github.com/nodejs/release-keys and re-run for full chain-of-trust."
  fi
fi

verify_sha() {
  local tarball="$1"
  echo "→ Verifying SHA256 of $tarball"
  (cd "$TMP_DIR" && grep -F "  $tarball" SHASUMS256.txt | "${SHASUM_CHECK[@]}") \
    || { echo "✗ SHA256 verification FAILED for $tarball — aborting" >&2; exit 1; }
}

echo "→ Fetching $ARM_TARBALL"
curl -fsSL "${BASE_URL}/${ARM_TARBALL}" -o "$TMP_DIR/$ARM_TARBALL"
verify_sha "$ARM_TARBALL"
echo "→ Extracting arm64"
tar -xzf "$TMP_DIR/$ARM_TARBALL" -C "$TMP_DIR"
ARM_DIR="$TMP_DIR/node-${VERSION}-darwin-arm64"

if [[ ! -x "$ARM_DIR/bin/node" ]]; then
  echo "✗ Extracted Node binary missing — aborting" >&2
  exit 1
fi

X64_DIR=""
if [[ $UNIVERSAL -eq 1 ]]; then
  X64_TARBALL="node-${VERSION}-darwin-x64.tar.gz"
  echo "→ Fetching $X64_TARBALL (--universal mode)"
  curl -fsSL "${BASE_URL}/${X64_TARBALL}" -o "$TMP_DIR/$X64_TARBALL"
  verify_sha "$X64_TARBALL"
  echo "→ Extracting x64"
  tar -xzf "$TMP_DIR/$X64_TARBALL" -C "$TMP_DIR"
  X64_DIR="$TMP_DIR/node-${VERSION}-darwin-x64"
  if [[ ! -x "$X64_DIR/bin/node" ]]; then
    echo "✗ Extracted Node x64 binary missing — aborting" >&2
    exit 1
  fi
fi

echo "→ Verifying versions"
"$ARM_DIR/bin/node" --version
[[ -n "$X64_DIR" ]] && "$X64_DIR/bin/node" --version

# Stage destination.
rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR/bin" "$VENDOR_DIR/lib/node_modules"

if [[ $UNIVERSAL -eq 1 ]]; then
  echo "→ Creating universal node binary via lipo"
  lipo -create \
    "$ARM_DIR/bin/node" \
    "$X64_DIR/bin/node" \
    -output "$VENDOR_DIR/bin/node"
else
  echo "→ Copying arm64 node binary (use --universal for x86_64 support)"
  cp "$ARM_DIR/bin/node" "$VENDOR_DIR/bin/node"
fi
chmod +x "$VENDOR_DIR/bin/node"

# npm + npx are JS-based — same JS regardless of CPU arch. Use the
# arm64 dist's npm copy.
echo "→ Staging npm + npx alongside node"
cp -R "$ARM_DIR/lib/node_modules/npm" "$VENDOR_DIR/lib/node_modules/npm"
ln -sf "../lib/node_modules/npm/bin/npm-cli.js" "$VENDOR_DIR/bin/npm"
ln -sf "../lib/node_modules/npm/bin/npx-cli.js" "$VENDOR_DIR/bin/npx"
# Make the shims executable by shebang.
chmod +x "$VENDOR_DIR/lib/node_modules/npm/bin/npm-cli.js"
chmod +x "$VENDOR_DIR/lib/node_modules/npm/bin/npx-cli.js"

# Drop a thin wrapper that runs the bundled npm via the bundled node.
# Replaces the symlink with a script — needed because npm-cli.js's
# shebang is `#!/usr/bin/env node` which would find SYSTEM node, not
# the bundled one, defeating the whole purpose of bundling.
#
# IMPORTANT: rm the symlink first. Without this, `cat > bin/npm`
# follows the symlink and clobbers `lib/node_modules/npm/bin/npm-cli.js`
# (the actual npm code) with this bash wrapper text — breaks npm entirely.
rm -f "$VENDOR_DIR/bin/npm" "$VENDOR_DIR/bin/npx"
cat > "$VENDOR_DIR/bin/npm" <<'NPM_WRAPPER'
#!/usr/bin/env bash
# Bundled-Node-aware npm wrapper. Always uses the sibling `node` binary,
# never PATH-resolved node — so we get the npm/node version pair we tested.
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/node" "$DIR/../lib/node_modules/npm/bin/npm-cli.js" "$@"
NPM_WRAPPER
chmod +x "$VENDOR_DIR/bin/npm"

cat > "$VENDOR_DIR/bin/npx" <<'NPX_WRAPPER'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/node" "$DIR/../lib/node_modules/npm/bin/npx-cli.js" "$@"
NPX_WRAPPER
chmod +x "$VENDOR_DIR/bin/npx"

# Record pinned version for the fast-path check above.
echo "$VERSION" > "$VERSION_FILE"

echo "→ Bundled Node ready: $VENDOR_DIR/bin/node"
"$VENDOR_DIR/bin/node" --version
"$VENDOR_DIR/bin/npm" --version

echo "✓ Done. Size:"
du -sh "$VENDOR_DIR"
