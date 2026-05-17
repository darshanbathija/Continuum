#!/usr/bin/env bash
#
# configure-c-shims.sh — Validate that every system library backing a
# CXxx module map is installed and discoverable via pkg-config.
#
# Run before `swift build` in linux/ on a new Linux dev machine; the
# script names missing packages so the install hint is clear.
#
# Per D9: this replaces hardcoded `/usr/include/...` paths with
# pkg-config-resolved discovery. The actual `-I` and `-l` flags for each
# shim get injected into the swift build via Package.swift's
# cSettings/.unsafeFlags(pkgConfigCflags("<name>")) helper invoked at
# build time (added when the C shim targets are wired up in Phase 3).

set -euo pipefail

if ! command -v pkg-config >/dev/null 2>&1; then
    echo "ERROR: pkg-config not installed. Run: sudo apt install pkg-config" >&2
    exit 1
fi

# Map: shim name → pkg-config package name → apt install hint
declare -A SHIMS
SHIMS["CCairo"]="cairo|libcairo2-dev"
SHIMS["CAyatanaAppIndicator"]="ayatana-appindicator3-0.1|libayatana-appindicator3-dev"
SHIMS["CLibSecret"]="libsecret-1|libsecret-1-dev"
SHIMS["CGtk4"]="gtk4|libgtk-4-dev"
SHIMS["CLibAdwaita"]="libadwaita-1|libadwaita-1-dev"
SHIMS["CWebKitGTK"]="webkitgtk-6.0|libwebkitgtk-6.0-dev"
SHIMS["CVTE"]="vte-2.91-gtk4|libvte-2.91-gtk4-dev"
SHIMS["CDBus"]="dbus-1|libdbus-1-dev"
# CLibUtil isn't pkg-config-tracked; libutil is in libc-bin (always present).

MISSING=0
for shim in "${!SHIMS[@]}"; do
    pc="${SHIMS[$shim]%%|*}"
    apt="${SHIMS[$shim]##*|}"
    if pkg-config --exists "$pc"; then
        version=$(pkg-config --modversion "$pc")
        echo "  ok    $shim ($pc $version)"
    else
        echo "  MISS  $shim ($pc) — install: sudo apt install -y $apt"
        MISSING=$((MISSING + 1))
    fi
done

if [ "$MISSING" -gt 0 ]; then
    echo
    echo "ERROR: $MISSING shim(s) missing. Install the named packages, then re-run."
    exit 1
fi

echo
echo "All C shim deps satisfied. Ready for: swift build"
