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

# P1-Linux-3: fail loud instead of silently exiting 0. Downstream
# packaging steps (CI upload, release publish, install-test) expect a
# real artifact at dist/Clawdmeter-<version>-x86_64.AppImage. Without
# this guard the upload step ran with `if-no-files-found: warn` and
# the CI run looked green even though no .AppImage was produced.
#
# Set CLAWDMETER_PACKAGING_ALLOW_STUB=1 to keep the legacy exit-0
# behaviour during local development where the toolchain isn't wired.
EXPECTED_ARTIFACT="$DIST_DIR/Clawdmeter-${VERSION}-x86_64.AppImage"
if [ ! -f "$EXPECTED_ARTIFACT" ]; then
    if [ "${CLAWDMETER_PACKAGING_ALLOW_STUB:-0}" = "1" ]; then
        echo "Stub mode (CLAWDMETER_PACKAGING_ALLOW_STUB=1) — exiting 0 without artifact." >&2
        exit 0
    fi
    echo "ERROR: AppImage not produced at $EXPECTED_ARTIFACT." >&2
    echo "       Implement the Phase 7 build pipeline above, or run with" >&2
    echo "       CLAWDMETER_PACKAGING_ALLOW_STUB=1 to keep the stub exit-0 behaviour." >&2
    exit 2
fi
echo "AppImage built: $EXPECTED_ARTIFACT"
