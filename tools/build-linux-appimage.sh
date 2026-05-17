#!/usr/bin/env bash
#
# build-linux-appimage.sh — Build a Clawdmeter AppImage for distribution.
#
# Phase 0 stub: prints intended pipeline + exits. Real implementation
# lands in Phase 7 (Packaging).
#
# Output: dist/Clawdmeter-<version>-x86_64.AppImage (~200MB once bundled)
#
# Required on the build host:
#   - Swift 6.0+ (from swift.org)
#   - linuxdeploy + appimagetool (https://appimage.github.io/)
#   - libgtk-4-dev, libadwaita-1-dev, libayatana-appindicator3-dev,
#     libsecret-1-dev, libcairo2-dev, libpango1.0-dev,
#     libwebkitgtk-6.0-dev, libvte-2.91-gtk4-dev
#   - bubblewrap + xdg-dbus-proxy (bundled into AppImage per codex C9)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINUX_DIR="$REPO_ROOT/linux"
DIST_DIR="$REPO_ROOT/dist"
VERSION_FILE="$REPO_ROOT/VERSION"

if [ ! -f "$VERSION_FILE" ]; then
    echo "ERROR: VERSION file not found at $VERSION_FILE" >&2
    exit 1
fi
VERSION="$(cat "$VERSION_FILE" | tr -d '[:space:]')"

echo "build-linux-appimage.sh (Phase 0 stub)"
echo "  Version:       $VERSION"
echo "  Linux dir:     $LINUX_DIR"
echo "  Dist dir:      $DIST_DIR"
echo
echo "Phase 7 will implement:"
echo "  1. swift build -c release in linux/"
echo "  2. linuxdeploy --appdir AppDir/ + bundle libswift*.so + libwebkitgtk-6.0 + libvte-2.91-gtk4 + bubblewrap + xdg-dbus-proxy + GStreamer plugins"
echo "  3. appimagetool AppDir → dist/Clawdmeter-${VERSION}-x86_64.AppImage"
exit 0
