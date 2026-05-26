#!/usr/bin/env bash
# Build a downloadable Clawdmeter.dmg for Apple Silicon Macs.
#
# Idempotent: re-run any time. Writes to ./dist/Clawdmeter-<version>-arm64.dmg.
#
# Self-serve for users:
#   1. Download the DMG from GitHub Releases
#   2. Open it
#   3. Drag Clawdmeter.app into the Applications folder
#   4. First launch: right-click Clawdmeter.app → Open (because the GitHub
#      DMG is not Apple-notarized — Gatekeeper asks the user to confirm
#      exactly once, then trusts it forever).
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
# v0.29.8: PRODUCT_NAME in apple/project.yml is now "Continuum", so
# the bundle on disk + the xcarchive + the export folder all carry
# that name. APP_NAME drives both the .app folder lookup and the DMG
# filename, so it follows. CFBundleIdentifier stays com.clawdmeter.mac
# (see project.yml comment) so existing installs keep their data —
# only the visible name and the .app folder rename.
APP_NAME="Continuum"
DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$REPO_ROOT/.build/mac-dmg"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGING_DIR="$BUILD_DIR/staging"

if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
  echo "✗ xcodebuild requires full Xcode. Install Xcode or run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

# Pull the marketing version from the Mac target's Info.plist via xcodebuild.
VERSION="$(/usr/bin/xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/MARKETING_VERSION/ && !seen {print $2; seen=1}' \
    | tr -d '[:space:]')"

# Fall back to the value in Info.plist if marketing version isn't set.
if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      apple/ClawdmeterMac/Info.plist 2>/dev/null || echo "0.1.0")"
fi

DMG_NAME="${APP_NAME}-${VERSION}-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

echo "▸ Building ${APP_NAME} v${VERSION} (arm64 / macOS Release)"
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
# fall back to copying the .app straight out of the archive. Personal-team
# Apple Development exports are re-signed ad-hoc below after stripping the
# embedded provisioning profile, because that profile can fail launchd
# entitlement validation on downloaded GitHub release builds. Gatekeeper still
# requires a right-click → Open on first launch because notarization needs a
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

# ────────────────────────────────────────────────────────────────────────
# 4b. v0.29.4: re-sign the Vendor/opencode helper binary.
#
# opencode ships ad-hoc signed (TeamIdentifier=not set). When it spawns
# Bun and Bun extracts native modules to TMPDIR with names like
# `.bbb6ffeffdf6fffd-00000000.dylib`, macOS Tahoe's XProtect can't find
# a trust chain on the loader process and pops the "could not verify
# is free of malware" dialog every time. Re-signing with our developer
# identity + hardened runtime + library-validation-disabled gives the
# helper a trust chain (so XProtect lets it through) while still
# allowing Bun's runtime dlopens of unsigned dylibs.
#
# The main app is signed by Xcode's export step above; only the
# vendored helpers need this pass.
# ────────────────────────────────────────────────────────────────────────

HELPER_ENT="$REPO_ROOT/apple/ClawdmeterMac/OpenCodeHelper.entitlements"
HELPER_BINARIES=(
  "$APP_PATH/Contents/Resources/Vendor/opencode/opencode"
  "$APP_PATH/Contents/Resources/Vendor/uv/uv"
)

# Pick the Apple Development identity used to sign the outer app, so the
# helpers inherit the same trust chain.
#
# Use the leaf cert's SHA1 hash rather than the human-readable Common
# Name: on machines where the cert has been renewed in-place, the
# keychain can hold two certs with the same CN
# ("Apple Development: ...") that resolve to different SHA1s, and
# `codesign --sign <CN>` aborts with "ambiguous identity". The SHA1 is
# always unique, and we extract it directly from the app xcodebuild
# just signed so we provably match its trust chain.
#
# Subtle: under `set -euo pipefail`, `awk … exit` closes the pipe early,
# codesign gets SIGPIPE → 141 → the whole substitution fails → script
# dies silently. Read all of codesign's output into a temp file, then
# pipe through openssl so no early-exit consumer can SIGPIPE codesign.
CERT_DIR="$(mktemp -d)"
codesign -d --extract-certificates="$CERT_DIR/cert" "$APP_PATH" 2>/dev/null || true
# Always read the full codesign descriptor so the outer-resign step
# below can pull the TeamIdentifier out of it (needed to expand the
# `$(AppIdentifierPrefix)` macro in the entitlements file). The SIGPIPE
# guard via `|| true` keeps `set -euo pipefail` from killing the script
# if `codesign` writes to stderr before its stdout consumer closes.
CODESIGN_INFO="$(codesign -dvvv "$APP_PATH" 2>&1 || true)"
SIGNING_IDENTITY=""
if [[ -f "$CERT_DIR/cert0" ]]; then
  SIGNING_IDENTITY="$(openssl x509 -inform DER -in "$CERT_DIR/cert0" \
      -noout -fingerprint -sha1 2>/dev/null \
      | sed -e 's/^SHA1 Fingerprint=//' -e 's/://g' \
      || true)"
fi
# Fallback to the CN if SHA1 extraction failed for any reason.
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(printf '%s\n' "$CODESIGN_INFO" \
      | grep -E '^Authority=Apple Development' \
      | head -n1 \
      | sed 's/^Authority=//' || true)"
fi
rm -rf "$CERT_DIR"

if printf '%s\n' "$CODESIGN_INFO" | grep -qE '^Authority=Apple Development'; then
  echo "▸ Apple Development export detected — stripping provisioning profile and ad-hoc re-signing"
  # Personal-team Apple Development exports can embed a provisioning
  # profile whose allowed entitlements do not match the final Mac app
  # entitlements after the helper/outer re-sign pass. That launches as:
  #   RBSRequestErrorDomain Code=5 / NSPOSIXErrorDomain Code=163
  # Gatekeeper is a separate notarization issue; this fixes the actual
  # launchd entitlement/provisioning mismatch for GitHub DMG users.
  rm -f "$APP_PATH/Contents/embedded.provisionprofile"
  codesign --force --deep --sign - "$APP_PATH" 2>&1 | sed 's/^/    /'
elif [[ -n "$SIGNING_IDENTITY" && -f "$HELPER_ENT" ]]; then
  echo "▸ Re-signing bundled helpers with: $SIGNING_IDENTITY"
  for HELPER in "${HELPER_BINARIES[@]}"; do
    if [[ -f "$HELPER" ]]; then
      codesign --force \
        --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --entitlements "$HELPER_ENT" \
        --timestamp=none \
        "$HELPER" 2>&1 | sed 's/^/    /' || echo "    ⚠ codesign failed for $HELPER"
    fi
  done
  # Re-sign the outer app so its sealed-resources manifest matches the
  # updated helpers (otherwise --deep verify rejects the bundle).
  #
  # Two subtleties:
  #
  # 1. `$(AppIdentifierPrefix)` macros — Xcode expands these at sign
  #    time using the project's resolved team prefix. Standalone
  #    `codesign --entitlements` does NOT expand them; it would embed
  #    the literal `$(AppIdentifierPrefix)com.clawdmeter` as the
  #    keychain-access-group, which Gatekeeper / launchd reject ("the
  #    application cannot be opened for an unexpected reason …
  #    Launchd job spawn failed", error 163). Expand the macro into a
  #    temp entitlements file using the team id we already extracted
  #    from the outer binary's CMS chain.
  #
  # 2. `--options runtime` on the outer app — the main app was signed
  #    by xcodebuild with `flags=0x0(none)`, NOT the hardened runtime.
  #    Adding `runtime` post-hoc enables library validation on the
  #    main binary's children, which can refuse to load bundled
  #    Swift / SwiftUI dylibs that were signed without the runtime
  #    flag. Helpers (opencode, uv) get hardened runtime because
  #    they're external pre-built binaries; the main Mac app stays
  #    on its xcodebuild defaults.
  TEAM_ID="$(printf '%s\n' "$CODESIGN_INFO" \
      | grep -E '^TeamIdentifier=' \
      | head -n1 \
      | sed 's/^TeamIdentifier=//' || true)"
  if [[ -z "$TEAM_ID" ]]; then
    echo "    ⚠ Skipping outer re-sign — could not determine team id"
  else
    OUTER_ENT="$(mktemp -t outer-ent.XXXXXX.plist)"
    sed "s|\$(AppIdentifierPrefix)|${TEAM_ID}.|g" \
        "$REPO_ROOT/apple/ClawdmeterMac/ClawdmeterMac-Release.entitlements" \
        > "$OUTER_ENT"
    codesign --force \
      --sign "$SIGNING_IDENTITY" \
      --entitlements "$OUTER_ENT" \
      --timestamp=none \
      "$APP_PATH" 2>&1 | sed 's/^/    /' || echo "    ⚠ outer codesign failed"
    rm -f "$OUTER_ENT"
  fi
else
  echo "⚠ Skipping helper re-sign — no Apple Development identity on outer app"
fi

# Verify the signature didn't break in export
codesign --verify --deep --strict "$APP_PATH" 2>&1 | head -5 || true

# ────────────────────────────────────────────────────────────────────────
# 5. Stage the DMG payload
# ────────────────────────────────────────────────────────────────────────

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Drop a short README into the DMG so users see install instructions on mount.
# v0.29.8: PRODUCT_NAME flip means the .app on disk is now called
# Continuum.app. If the user is upgrading from v0.29.7 or earlier they'll
# end up with both /Applications/Clawdmeter.app (legacy) and
# /Applications/Continuum.app — call that out so they know which to
# trash. Bundle identifier is unchanged, so data + sessions follow the
# new app automatically.
cat > "$STAGING_DIR/INSTALL.txt" <<'README'
Continuum for Mac
=================

1. Drag Continuum.app into the Applications folder.
2. If you have an existing /Applications/Clawdmeter.app from before
   v0.29.8, drag it to the Trash now — it's the previous name of the
   same app. Your data, sessions, and pairing carry over to Continuum.app
   automatically (the bundle identifier didn't change).
3. First launch: right-click Continuum.app in Applications → Open →
   "Open" in the dialog. macOS asks once because the GitHub DMG is not
   Apple-notarized. After the first Open, Gatekeeper remembers and never
   asks again.
4. The Continuum icon appears in the menu bar. Click it to view your
   Claude / Codex usage; click "Open dashboard" for the full window.

Source, watchOS / iOS apps, and release notes:
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
# hdiutil's `attach` output can include multiple lines when other DMGs
# are already mounted or when the disk has both a partition map and a
# data partition. Grep for the first /Volumes/... path explicitly so
# we always land on the new mount, not the last-line of stale output.
MOUNT_POINT=$(hdiutil attach -nobrowse -readonly "$DMG_PATH" 2>&1 \
  | grep -o '/Volumes/[^ ]*' | head -1)
if [[ -d "$MOUNT_POINT/${APP_NAME}.app" ]]; then
  echo "✓ DMG mounts and contains ${APP_NAME}.app"
  codesign --verify --deep --strict "$MOUNT_POINT/${APP_NAME}.app" 2>&1 | head -3 || true
else
  echo "✗ DMG mounted but no ${APP_NAME}.app inside"
fi

# v0.14.0 (plan v2.1 T17): smoke-check that the bundled Open Design tree
# made it into the .app — Design tab will be broken otherwise. Runs while
# the DMG is still mounted so paths are valid.
if [[ -d "$MOUNT_POINT/${APP_NAME}.app" ]]; then
  OD_DAEMON="$MOUNT_POINT/${APP_NAME}.app/Contents/Resources/Vendor/open-design/apps/daemon/dist/cli.js"
  OD_WEB="$MOUNT_POINT/${APP_NAME}.app/Contents/Resources/Vendor/open-design/apps/web/out/index.html"
  OD_BRIDGE="$MOUNT_POINT/${APP_NAME}.app/Contents/Resources/Vendor/open-design/bridge-host/index.js"
  if [[ -f "$OD_DAEMON" && -f "$OD_WEB" && -f "$OD_BRIDGE" ]]; then
    echo "✓ Vendor/open-design/ daemon + web + bridge present in DMG"
  else
    echo "⚠ Vendor/open-design/ tree incomplete inside DMG (Design tab inert):"
    [[ -f "$OD_DAEMON" ]] || echo "    missing: apps/daemon/dist/cli.js"
    [[ -f "$OD_WEB"    ]] || echo "    missing: apps/web/out/index.html"
    [[ -f "$OD_BRIDGE" ]] || echo "    missing: bridge-host/index.js"
    echo "  Run tools/build-bundled-open-design.sh and re-run this script."
  fi
fi
hdiutil detach "$MOUNT_POINT" -quiet

# v0.14.0 (plan v2.1 T17): DMG size budget guard. Soft budget 350MB,
# hard limit 400MB to catch regressions.
DMG_BYTES="$(stat -f%z "$DMG_PATH")"
BUDGET_MB=350
HARD_MB=400
DMG_MB=$((DMG_BYTES / 1024 / 1024))
if (( DMG_MB > HARD_MB )); then
  echo "✗ DMG size ${DMG_MB}MB exceeds hard limit ${HARD_MB}MB"
  exit 1
elif (( DMG_MB > BUDGET_MB )); then
  echo "⚠ DMG size ${DMG_MB}MB exceeds budget ${BUDGET_MB}MB — review what grew"
else
  echo "✓ DMG size ${DMG_MB}MB within budget (${BUDGET_MB}MB soft / ${HARD_MB}MB hard)"
fi

echo ""
echo "✅ Done."
echo "   $DMG_PATH"
echo "   Distribute via GitHub Releases (see tools/release-mac.sh)."
