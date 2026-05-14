#!/usr/bin/env bash
# Build a downloadable Clawdmeter.dmg for Apple Silicon Macs.
#
# Idempotent: re-run any time. Writes to ./dist/Clawdmeter-<version>-arm64.dmg.
#
# Self-serve for users:
#   1. Download the DMG from GitHub Releases
#   2. Open it
#   3. Drag Clawdmeter.app into the Applications folder
#   4. First launch: right-click Clawdmeter.app → Open (because the build is
#      signed with a personal Apple Developer team, not notarized — Gatekeeper
#      asks the user to confirm exactly once, then trusts it forever).
#
# Self-serve for builders (run this on any Apple Silicon Mac with Xcode):
#   cd /path/to/Clawdmeter && ./tools/build-mac-dmg.sh
#
# Requires: macOS, Xcode CLT (xcodebuild + hdiutil + codesign — all built-in).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ────────────────────────────────────────────────────────────────────────
# Configuration
# ────────────────────────────────────────────────────────────────────────

SCHEME="Clawdmeter (Mac)"
PROJECT="apple/Clawdmeter.xcodeproj"
APP_NAME="Clawdmeter"
DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$REPO_ROOT/.build/mac-dmg"
ARCHIVE_PATH="$BUILD_DIR/Clawdmeter.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGING_DIR="$BUILD_DIR/staging"

# Pull the marketing version from the Mac target's Info.plist via xcodebuild.
VERSION="$(/usr/bin/xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/MARKETING_VERSION/ {print $2; exit}' \
    | tr -d '[:space:]')"

# Fall back to the value in Info.plist if marketing version isn't set.
if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      apple/ClawdmeterMac/Info.plist 2>/dev/null || echo "0.1.0")"
fi

DMG_NAME="${APP_NAME}-${VERSION}-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

echo "▸ Building Clawdmeter v${VERSION} (arm64 / macOS Release)"
echo "  scheme:    $SCHEME"
echo "  project:   $PROJECT"
echo "  output:    $DMG_PATH"
echo ""

# ────────────────────────────────────────────────────────────────────────
# 1. Clean output dirs
# ────────────────────────────────────────────────────────────────────────

mkdir -p "$DIST_DIR" "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# ────────────────────────────────────────────────────────────────────────
# 2. Regenerate the Xcode project (xcodegen is the source of truth)
# ────────────────────────────────────────────────────────────────────────

if command -v xcodegen >/dev/null 2>&1; then
  ( cd apple && xcodegen >/dev/null )
  echo "✓ Xcode project regenerated via xcodegen"
else
  echo "⚠ xcodegen not installed — using whatever's already in $PROJECT"
fi

# ────────────────────────────────────────────────────────────────────────
# 3. Archive the Mac app (Release, arm64)
# ────────────────────────────────────────────────────────────────────────

echo "▸ Archiving (this takes ~30s)…"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  -quiet
echo "✓ Archive: $ARCHIVE_PATH"

# ────────────────────────────────────────────────────────────────────────
# 4. Export the .app from the archive
# ────────────────────────────────────────────────────────────────────────

# Personal-team signing → use developer-id-distribution where possible, but
# fall back to copying the .app straight out of the archive (which uses the
# embedded "Apple Development" signature — works for local use, but Gatekeeper
# will require a right-click → Open on first launch). Notarization needs a
# paid Apple Developer Program account, which this repo doesn't have.

EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
PLIST

set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$EXPORT_DIR" \
  -quiet
EXPORT_EXIT=$?
set -e

if [[ $EXPORT_EXIT -ne 0 || ! -d "$EXPORT_DIR/${APP_NAME}.app" ]]; then
  echo "⚠ exportArchive failed — falling back to direct archive copy"
  mkdir -p "$EXPORT_DIR"
  cp -R "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" "$EXPORT_DIR/"
fi

APP_PATH="$EXPORT_DIR/${APP_NAME}.app"
[[ -d "$APP_PATH" ]] || { echo "✗ No .app produced"; exit 1; }
echo "✓ App exported: $APP_PATH"

# Verify the signature didn't break in export
codesign --verify --deep --strict "$APP_PATH" 2>&1 | head -5 || true

# ────────────────────────────────────────────────────────────────────────
# 5. Stage the DMG payload
# ────────────────────────────────────────────────────────────────────────

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Drop a short README into the DMG so users see install instructions on mount.
cat > "$STAGING_DIR/INSTALL.txt" <<'README'
Clawdmeter for Mac
==================

1. Drag Clawdmeter.app into the Applications folder.
2. First launch: right-click Clawdmeter.app → Open → "Open" in the dialog.
   (macOS asks once because Clawdmeter is signed with a personal Apple
    Developer team, not notarized. After the first Open, Gatekeeper
    remembers and never asks again.)
3. The Clawdmeter icon appears in the menu bar. Click it to view your
   Claude / Codex usage; click "Open dashboard" for the full window.

For the source, the watchOS / iOS apps, and the original ESP32 firmware:
https://github.com/darshanbathija/Clawdmeter
README

# ────────────────────────────────────────────────────────────────────────
# 6. Build the DMG with hdiutil (zlib-compressed, ~quarter the size of the
#    raw .app bundle)
# ────────────────────────────────────────────────────────────────────────

echo "▸ Building DMG…"
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH" >/dev/null

SIZE="$(du -h "$DMG_PATH" | awk '{print $1}')"
echo "✓ DMG: $DMG_PATH ($SIZE)"

# ────────────────────────────────────────────────────────────────────────
# 7. Verify the DMG mounts and the app is intact
# ────────────────────────────────────────────────────────────────────────

echo "▸ Verifying DMG…"
MOUNT_POINT=$(hdiutil attach -nobrowse -readonly "$DMG_PATH" | tail -1 | awk '{print $3}')
if [[ -d "$MOUNT_POINT/${APP_NAME}.app" ]]; then
  echo "✓ DMG mounts and contains ${APP_NAME}.app"
  codesign --verify --deep --strict "$MOUNT_POINT/${APP_NAME}.app" 2>&1 | head -3 || true
else
  echo "✗ DMG mounted but no ${APP_NAME}.app inside"
fi
hdiutil detach "$MOUNT_POINT" -quiet

echo ""
echo "✅ Done."
echo "   $DMG_PATH"
echo "   Distribute via GitHub Releases (see tools/release-mac.sh)."
