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

# P1-Linux-3: fail loud instead of silently exiting 0 when no .deb is
# produced. Without this, the CI matrix's upload + install-test steps
# downloaded zero artifacts and reported green. Set
# CLAWDMETER_PACKAGING_ALLOW_STUB=1 to keep the legacy stub behaviour
# during local development where the dpkg toolchain isn't available.
EXPECTED_ARTIFACT="$DIST_DIR/clawdmeter_${VERSION}_amd64.deb"
if [ ! -f "$EXPECTED_ARTIFACT" ]; then
    if [ "${CLAWDMETER_PACKAGING_ALLOW_STUB:-0}" = "1" ]; then
        echo "Stub mode (CLAWDMETER_PACKAGING_ALLOW_STUB=1) — exiting 0 without artifact." >&2
        exit 0
    fi
    echo "ERROR: .deb not produced at $EXPECTED_ARTIFACT." >&2
    echo "       Implement the Phase 7 build pipeline above, or run with" >&2
    echo "       CLAWDMETER_PACKAGING_ALLOW_STUB=1 to keep the stub exit-0 behaviour." >&2
    exit 2
fi
echo ".deb built: $EXPECTED_ARTIFACT"
