#!/usr/bin/env bash
# Download a Homebrew tmux bottle plus the dylibs tmux needs, relocate it
# into apple/ClawdmeterMac/Resources/Vendor/tmux/, and patch install names
# so the app can run tmux from inside Contents/Resources without requiring
# the user to install Homebrew.
#
# This is a build/release-time dependency only. End users get the staged
# binary inside the app bundle.

set -euo pipefail

TMUX_VERSION="3.6b"
BOTTLE_TAG="${CLAWDMETER_TMUX_BOTTLE_TAG:-arm64_tahoe}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/apple/ClawdmeterMac/Resources/Vendor/tmux"
BIN_DIR="$VENDOR_DIR/bin"
LIB_DIR="$VENDOR_DIR/lib"
LICENSE_DIR="$VENDOR_DIR/licenses"
TMP_DIR="$(mktemp -d -t clawdmeter-tmux-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "-> Bundled tmux target: $VENDOR_DIR (tmux $TMUX_VERSION, $BOTTLE_TAG)"

if ! command -v brew >/dev/null 2>&1; then
  echo "x Homebrew is required on the release/build machine to stage tmux bottles." >&2
  echo "  End users do not need Homebrew; the DMG ships the staged binary." >&2
  exit 1
fi

if ! command -v install_name_tool >/dev/null 2>&1; then
  echo "x install_name_tool is required. Install Xcode command line tools." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "x jq is required to verify bottle sha256 checksums." >&2
  echo "  brew install jq" >&2
  exit 1
fi

if ! command -v shasum >/dev/null 2>&1; then
  echo "x shasum is required to verify bottle sha256 checksums." >&2
  exit 1
fi

VERSION_FILE="$VENDOR_DIR/.bundled-version"
if [[ -f "$VERSION_FILE" ]] \
  && [[ "$(cat "$VERSION_FILE")" == "$TMUX_VERSION:$BOTTLE_TAG" ]] \
  && [[ -x "$BIN_DIR/tmux" ]] \
  && otool -L "$BIN_DIR/tmux" | grep -q '@executable_path/../lib'; then
  echo "-> Already at tmux $TMUX_VERSION for $BOTTLE_TAG; skipping download."
  exit 0
fi

fetch_and_extract() {
  local formula="$1"
  echo "-> Fetching $formula bottle"
  brew fetch --formula --bottle-tag="$BOTTLE_TAG" "$formula" >/dev/null
  local bottle
  bottle="$(brew --cache --bottle-tag="$BOTTLE_TAG" "$formula")"

  # Verify the bottle's sha256 matches the hash published in Homebrew's
  # formula manifest. Catches CDN tampering and MITM swaps — without
  # this check, `brew fetch` would silently bundle whatever bytes
  # arrived. The published hash itself is delivered via HTTPS by
  # `brew info`, so an attacker would need to compromise both channels.
  local expected_sha
  expected_sha="$(brew info --json=v2 "$formula" \
      | jq -r --arg tag "$BOTTLE_TAG" \
        '.formulae[0].bottle.stable.files[$tag].sha256 // empty')"
  if [[ -z "$expected_sha" ]]; then
    echo "x No published sha256 for $formula:$BOTTLE_TAG in brew info — refusing to bundle unverified bottle" >&2
    exit 1
  fi
  local actual_sha
  actual_sha="$(shasum -a 256 "$bottle" | awk '{print $1}')"
  if [[ "$expected_sha" != "$actual_sha" ]]; then
    echo "x sha256 mismatch for $formula bottle:" >&2
    echo "  expected: $expected_sha" >&2
    echo "  actual:   $actual_sha" >&2
    echo "  bottle:   $bottle" >&2
    exit 1
  fi
  echo "   sha256 verified: $actual_sha"

  # Reject tarballs that contain absolute paths or parent-directory
  # traversal before extracting. tar's own defenses are limited; this
  # is belt-and-suspenders to keep a hostile bottle from writing
  # outside $TMP_DIR.
  local bad
  bad="$(tar -tzf "$bottle" | awk '/^\// || /(^|\/)\.\.(\/|$)/' | head -1)"
  if [[ -n "$bad" ]]; then
    echo "x Refusing to extract $formula bottle — suspicious member: $bad" >&2
    exit 1
  fi

  # --no-same-owner blocks tarballs from forcing arbitrary uid/gid on
  # extracted files (which they can't actually set without root, but
  # tar issues warnings under set -e that we don't want).
  tar --no-same-owner -xzf "$bottle" -C "$TMP_DIR"
}

find_one() {
  local root="$1"
  local name="$2"
  local found
  found="$(find "$root" -type f -name "$name" -print -quit)"
  if [[ -z "$found" ]]; then
    echo "x Could not find $name under $root" >&2
    exit 1
  fi
  printf '%s\n' "$found"
}

fetch_and_extract tmux
fetch_and_extract libevent
fetch_and_extract ncurses
fetch_and_extract utf8proc

TMUX_SRC="$(find_one "$TMP_DIR/tmux" tmux)"
LIBEVENT_SRC="$(find_one "$TMP_DIR/libevent" libevent_core-2.1.7.dylib)"
NCURSES_SRC="$(find_one "$TMP_DIR/ncurses" libncursesw.6.dylib)"
UTF8PROC_SRC="$(find "$TMP_DIR/utf8proc" -type f -name 'libutf8proc.3.*.dylib' -print -quit)"
if [[ -z "$UTF8PROC_SRC" ]]; then
  echo "x Could not find libutf8proc.3.*.dylib under $TMP_DIR/utf8proc" >&2
  exit 1
fi
UTF8PROC_FILE="$(basename "$UTF8PROC_SRC")"

rm -rf "$VENDOR_DIR"
mkdir -p "$BIN_DIR" "$LIB_DIR" "$LICENSE_DIR"

cp "$TMUX_SRC" "$BIN_DIR/tmux"
cp "$LIBEVENT_SRC" "$LIB_DIR/libevent_core-2.1.7.dylib"
cp "$NCURSES_SRC" "$LIB_DIR/libncursesw.6.dylib"
cp "$UTF8PROC_SRC" "$LIB_DIR/$UTF8PROC_FILE"
ln -sf "$UTF8PROC_FILE" "$LIB_DIR/libutf8proc.3.dylib"
chmod +x "$BIN_DIR/tmux"

# Keep license files with the vendored binaries. The app does not render
# these yet, but the release artifact contains the attribution payload.
cp "$TMP_DIR/tmux"/*/COPYING "$LICENSE_DIR/tmux-COPYING" 2>/dev/null || true
cp "$TMP_DIR/libevent"/*/LICENSE "$LICENSE_DIR/libevent-LICENSE" 2>/dev/null || true
cp "$TMP_DIR/ncurses"/*/COPYING "$LICENSE_DIR/ncurses-COPYING" 2>/dev/null || true
cp "$TMP_DIR/utf8proc"/*/LICENSE.md "$LICENSE_DIR/utf8proc-LICENSE.md" 2>/dev/null || true

echo "-> Relocating dylib install names"
install_name_tool -id "@executable_path/../lib/libevent_core-2.1.7.dylib" \
  "$LIB_DIR/libevent_core-2.1.7.dylib"
install_name_tool -id "@executable_path/../lib/libncursesw.6.dylib" \
  "$LIB_DIR/libncursesw.6.dylib"
install_name_tool -id "@executable_path/../lib/libutf8proc.3.dylib" \
  "$LIB_DIR/$UTF8PROC_FILE"

install_name_tool \
  -change "@@HOMEBREW_PREFIX@@/opt/utf8proc/lib/libutf8proc.3.dylib" \
          "@executable_path/../lib/libutf8proc.3.dylib" \
  -change "@@HOMEBREW_PREFIX@@/opt/ncurses/lib/libncursesw.6.dylib" \
          "@executable_path/../lib/libncursesw.6.dylib" \
  -change "@@HOMEBREW_PREFIX@@/opt/libevent/lib/libevent_core-2.1.7.dylib" \
          "@executable_path/../lib/libevent_core-2.1.7.dylib" \
  "$BIN_DIR/tmux"

# Ad-hoc sign for local dev. tools/build-mac-dmg.sh re-signs the bundled
# helper with the app's release identity when one is available.
codesign --force --sign - "$LIB_DIR/libevent_core-2.1.7.dylib" >/dev/null 2>&1 || true
codesign --force --sign - "$LIB_DIR/libncursesw.6.dylib" >/dev/null 2>&1 || true
codesign --force --sign - "$LIB_DIR/$UTF8PROC_FILE" >/dev/null 2>&1 || true
codesign --force --sign - "$BIN_DIR/tmux" >/dev/null 2>&1 || true

if otool -L "$BIN_DIR/tmux" | grep -q '@@HOMEBREW_PREFIX@@'; then
  echo "x tmux still has Homebrew placeholder install names after relocation" >&2
  otool -L "$BIN_DIR/tmux" >&2
  exit 1
fi

"$BIN_DIR/tmux" -V
echo "$TMUX_VERSION:$BOTTLE_TAG" > "$VERSION_FILE"
echo "✓ Bundled tmux ready: $BIN_DIR/tmux ($(du -sh "$VENDOR_DIR" | cut -f1))"
