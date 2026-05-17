#!/usr/bin/env bash
#
# build-linux-deb.sh — Build a Clawdmeter .deb for Ubuntu 24.04+ / Zorin 17+.
#
# Phase 0 stub: prints intended pipeline + exits. Real implementation
# lands in Phase 7 (Packaging).
#
# Output: dist/clawdmeter_<version>_amd64.deb (~30MB; system GTK4 deps)
#
# Required on the build host:
#   - Swift 6.0+ (from swift.org)
#   - dpkg-deb
#   - same system deps as the AppImage build

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

echo "build-linux-deb.sh (Phase 0 stub)"
echo "  Version:       $VERSION"
echo "  Linux dir:     $LINUX_DIR"
echo "  Dist dir:      $DIST_DIR"
echo
echo "Phase 7 will implement:"
echo "  1. swift build -c release in linux/"
echo "  2. Stage into pkg/DEBIAN/ + /opt/clawdmeter/ + /usr/share/applications/"
echo "  3. Depends: libgtk-4-1 (>=4.14), libadwaita-1-0 (>=1.5), libayatana-appindicator3-1,"
echo "             libsecret-1-0, libwebkitgtk-6.0-4, libsoup-3.0-0, libvte-2.91-gtk4-0,"
echo "             bubblewrap, xdg-dbus-proxy"
echo "  4. dpkg-deb --build pkg → dist/clawdmeter_${VERSION}_amd64.deb"
exit 0
