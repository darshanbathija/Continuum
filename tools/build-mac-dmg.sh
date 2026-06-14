#!/usr/bin/env bash
# Build a downloadable Continuum.dmg for Apple Silicon Macs.
#
# Idempotent: re-run any time. Writes to ./dist/Continuum-<version>-arm64.dmg.
#
# Two signing modes, auto-detected:
#
#   1. Developer ID + notarized (PREFERRED — Gatekeeper opens it with no
#      warning). Triggered when a "Developer ID Application" identity is in the
#      keychain. The app + every bundled helper (opencode, uv)
#      is signed with the Developer ID cert + hardened runtime + a secure
#      timestamp, then the DMG is submitted to Apple's notary service and the
#      ticket is stapled. App Groups force a provisioning profile even for
#      Developer ID, so the Mac targets are signed manually against the
#      MAC_APP_DIRECT profiles (created once via the App Store Connect API —
#      see the project memory / fastlane continuum_* lanes).
#
#   2. Apple Development, un-notarized (FALLBACK — used on dev machines without
#      a Developer ID cert). Gatekeeper requires a right-click → Open once.
#
# Required for the notarized path:
#   - A "Developer ID Application: …" identity in the login keychain (only the
#     account holder can mint it: Xcode → Settings → Accounts → Manage
#     Certificates → + → Developer ID Application).
#   - MAC_APP_DIRECT provisioning profiles installed for ai.continuum.mac and
#     ai.continuum.mac.widgets (names below). Create with the fastlane
#     continuum_* helpers if missing.
#   - For notarization (optional but recommended): the App Store Connect API
#     key env — CLAWDMETER_ASC_KEY_ID / CLAWDMETER_ASC_ISSUER_ID and the .p8 at
#     ~/.appstoreconnect/private_keys/AuthKey_<id>.p8. Source ~/.continuum-ci.env.
#   - bundler + the apple/ Gemfile (for `fastlane run update_code_signing_settings`).
#
# Self-serve for builders:
#   cd /path/to/Clawdmeter && source ~/.continuum-ci.env && ./tools/build-mac-dmg.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ────────────────────────────────────────────────────────────────────────
# Configuration
# ────────────────────────────────────────────────────────────────────────

SCHEME="Clawdmeter (Mac)"
PROJECT="apple/Clawdmeter.xcodeproj"
APP_NAME="Continuum"
DEV_TEAM="${CLAWDMETER_TEAM_ID:-LRL8MRH6B4}"
# MAC_APP_DIRECT (Developer ID) profile names — created once via ConnectAPI.
MAC_PROFILE="Continuum DeveloperID ai.continuum.mac"
MAC_WIDGETS_PROFILE="Continuum DeveloperID ai.continuum.mac.widgets"

DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$REPO_ROOT/.build/mac-dmg"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
STAGING_DIR="$BUILD_DIR/staging"

# Regenerate the Xcode project FIRST (xcodegen is the source of truth) so the
# version read below reflects the CURRENT project.yml MARKETING_VERSION.
if command -v xcodegen >/dev/null 2>&1; then
  ( cd apple && xcodegen >/dev/null )
  echo "✓ Xcode project regenerated via xcodegen"
else
  echo "⚠ xcodegen not installed — using whatever's already in $PROJECT"
fi

VERSION="$(/usr/bin/xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/MARKETING_VERSION/ {print $2; exit}' \
    | tr -d '[:space:]')"
if [[ -z "$VERSION" || "$VERSION" == *'$('* ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
      apple/ClawdmeterMac/Info.plist 2>/dev/null || true)"
fi
if [[ -z "$VERSION" || "$VERSION" == *'$('* ]]; then
  VERSION="$(awk -F'"' '/MARKETING_VERSION:/ {print $2; exit}' apple/project.yml | tr -d '[:space:]')"
fi
if [[ -z "$VERSION" || "$VERSION" == *'$('* ]]; then
  VERSION="0.1.0"
fi

DMG_NAME="${APP_NAME}-${VERSION}-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

# ────────────────────────────────────────────────────────────────────────
# Signing-mode detection
# ────────────────────────────────────────────────────────────────────────

# SHA1 of the Developer ID Application identity (unique; CN can be ambiguous
# across renewed certs).
DEVID_ID="$(security find-identity -p codesigning -v 2>/dev/null \
    | awk '/Developer ID Application/ {print $2; exit}')"

NOTARIZE_READY=0
ASC_KEY_FILE="${HOME}/.appstoreconnect/private_keys/AuthKey_${CLAWDMETER_ASC_KEY_ID:-__none__}.p8"
if [[ -n "${CLAWDMETER_ASC_KEY_ID:-}" && -n "${CLAWDMETER_ASC_ISSUER_ID:-}" && -f "$ASC_KEY_FILE" ]]; then
  NOTARIZE_READY=1
fi

if [[ -n "$DEVID_ID" ]]; then
  SIGN_MODE="developerid"
else
  SIGN_MODE="development"
fi

echo "▸ Building ${APP_NAME} v${VERSION} (arm64 / macOS Release)"
echo "  scheme:    $SCHEME"
echo "  output:    $DMG_PATH"
echo "  signing:   $SIGN_MODE${DEVID_ID:+ ($DEVID_ID)}"
echo "  notarize:  $([[ $NOTARIZE_READY == 1 && $SIGN_MODE == developerid ]] && echo yes || echo no)"
echo ""

if [[ "$SIGN_MODE" == "developerid" && $NOTARIZE_READY != 1 && "${CLAWDMETER_ALLOW_UNNOTARIZED_DEVID:-0}" != "1" ]]; then
  echo "✗ Developer ID signing was detected, but App Store Connect notarization env is incomplete." >&2
  echo "  Source ~/.continuum-ci.env, or set CLAWDMETER_ALLOW_UNNOTARIZED_DEVID=1 for an explicit local-only build." >&2
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────
# 1. Clean output dirs
# ────────────────────────────────────────────────────────────────────────

mkdir -p "$DIST_DIR" "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# ────────────────────────────────────────────────────────────────────────
# 2. Bundled helpers
# ────────────────────────────────────────────────────────────────────────

if [[ "${CLAWDMETER_SKIP_BUNDLED_OPENCODE:-0}" != "1" ]]; then
  ./tools/download-bundled-opencode.sh
else
  echo "⚠ Skipping bundled opencode download (CLAWDMETER_SKIP_BUNDLED_OPENCODE=1)"
fi

if [[ "${CLAWDMETER_SKIP_BUNDLED_FFF:-0}" != "1" ]]; then
  ./tools/download-bundled-fff.sh
else
  echo "⚠ Skipping bundled FFF download (CLAWDMETER_SKIP_BUNDLED_FFF=1)"
fi

if [[ "${CLAWDMETER_SKIP_OPENCODE_FFF_PLUGIN:-0}" != "1" ]]; then
  ./tools/stage-opencode-fff-plugin.sh
else
  echo "⚠ Skipping OpenCode FFF plugin staging (CLAWDMETER_SKIP_OPENCODE_FFF_PLUGIN=1)"
fi

# ────────────────────────────────────────────────────────────────────────
# 3. (Developer ID only) point the Mac targets at the MAC_APP_DIRECT profiles
#    with manual signing. App Groups require a profile even for Developer ID,
#    so automatic signing can't produce a notarizable archive here. This patches
#    the freshly-generated .xcodeproj (xcodegen reverts it on the next run).
# ────────────────────────────────────────────────────────────────────────

if [[ "$SIGN_MODE" == "developerid" ]]; then
  # Prefer Homebrew Ruby's bundle (system Ruby ships an old bundler version
  # incompatible with the Gemfile.lock BUNDLED WITH constraint).
  BUNDLE_BIN="${CLAWDMETER_BUNDLE_BIN:-/opt/homebrew/opt/ruby/bin/bundle}"
  [[ -x "$BUNDLE_BIN" ]] || BUNDLE_BIN="$(command -v bundle || true)"
  if [[ -x "$BUNDLE_BIN" ]] && [[ -f apple/Gemfile ]]; then
    echo "▸ Setting manual Developer ID signing on the Mac targets…"
    (
      cd apple
      export BUNDLE_PATH="${BUNDLE_PATH:-$HOME/.continuum-fastlane}"
      for pair in "ClawdmeterMac:$MAC_PROFILE" "ClawdmeterMacWidgets:$MAC_WIDGETS_PROFILE"; do
        tgt="${pair%%:*}"; prof="${pair#*:}"
        "$BUNDLE_BIN" exec fastlane run update_code_signing_settings \
          path:"Clawdmeter.xcodeproj" use_automatic_signing:false team_id:"$DEV_TEAM" \
          targets:"$tgt" code_sign_identity:"Developer ID Application" \
          profile_name:"$prof" >/dev/null 2>&1
        echo "  ✓ $tgt → $prof"
      done
    )
  else
    echo "✗ bundler/fastlane not found — cannot set manual Developer ID signing." >&2
    exit 1
  fi
fi

# ────────────────────────────────────────────────────────────────────────
# 4. Archive (Release, arm64). Developer ID → hardened runtime + secure
#    timestamp so the result is notarizable.
# ────────────────────────────────────────────────────────────────────────

echo "▸ Archiving (this takes ~30-60s)…"
ARCHIVE_ARGS=(
  -project "$PROJECT" -scheme "$SCHEME" -configuration Release
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE_PATH"
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO
)
if [[ "$SIGN_MODE" == "developerid" ]]; then
  ARCHIVE_ARGS+=( ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" )
fi
xcodebuild archive "${ARCHIVE_ARGS[@]}" -quiet
echo "✓ Archive: $ARCHIVE_PATH"

# ────────────────────────────────────────────────────────────────────────
# 5. Get the .app out of the archive
# ────────────────────────────────────────────────────────────────────────

mkdir -p "$EXPORT_DIR"
if [[ "$SIGN_MODE" == "developerid" ]]; then
  # The archive is already Developer-ID-signed with the embedded profiles +
  # hardened runtime, so copy the .app straight out. (exportArchive would
  # re-sign and strip the bundled-helper signatures we fix below.)
  cp -R "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" "$EXPORT_DIR/"
else
  EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
  cat > "$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>mac-application</string>
    <key>destination</key><string>export</string>
    <key>signingStyle</key><string>automatic</string>
    <key>stripSwiftSymbols</key><true/>
</dict>
</plist>
PLIST
  set +e
  xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_PLIST" -exportPath "$EXPORT_DIR" -quiet
  EXPORT_EXIT=$?
  set -e
  if [[ $EXPORT_EXIT -ne 0 || ! -d "$EXPORT_DIR/${APP_NAME}.app" ]]; then
    echo "⚠ exportArchive failed — falling back to direct archive copy"
    cp -R "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" "$EXPORT_DIR/"
  fi
fi

APP_PATH="$EXPORT_DIR/${APP_NAME}.app"
[[ -d "$APP_PATH" ]] || { echo "✗ No .app produced"; exit 1; }
echo "✓ App exported: $APP_PATH"

REQUIRED_VENDOR_BINS=(
  "$APP_PATH/Contents/Resources/Vendor/opencode/opencode"
  "$APP_PATH/Contents/Resources/Vendor/uv/uv"
  "$APP_PATH/Contents/Resources/Vendor/fff/fff-mcp"
)
REQUIRED_VENDOR_LIBS=(
  "$APP_PATH/Contents/Resources/Vendor/fff/libfff_c.dylib"
)
for BIN in "${REQUIRED_VENDOR_BINS[@]}"; do
  if [[ ! -x "$BIN" ]]; then
    echo "✗ Required bundled runtime missing or not executable: $BIN" >&2
    echo "  Re-run without CLAWDMETER_SKIP_BUNDLED_* overrides." >&2
    exit 1
  fi
done
for LIB in "${REQUIRED_VENDOR_LIBS[@]}"; do
  if [[ ! -f "$LIB" ]]; then
    echo "✗ Required bundled library missing: $LIB" >&2
    echo "  Re-run without CLAWDMETER_SKIP_BUNDLED_* overrides." >&2
    exit 1
  fi
done

# ────────────────────────────────────────────────────────────────────────
# 6. Re-sign the bundled helper binaries.
#
# opencode + uv ship ad-hoc (TeamIdentifier=not set); node is already Developer-ID-signed by the
# Node.js Foundation (left as-is — third-party Developer-ID binaries pass
# notarization). For notarization every Mach-O must carry hardened runtime +
# a secure timestamp, so we re-sign the ad-hoc ones with our identity.
#
# opencode + uv additionally get disable-library-validation (Bun dlopens
# unsigned modules from TMPDIR — see OpenCodeHelper.entitlements). The outer
# app is re-sealed afterwards so its resource manifest matches.
# ────────────────────────────────────────────────────────────────────────

HELPER_ENT="$REPO_ROOT/apple/ClawdmeterMac/OpenCodeHelper.entitlements"
V="$APP_PATH/Contents/Resources/Vendor"

if [[ "$SIGN_MODE" == "developerid" ]]; then
  SIGN_ID="$DEVID_ID"
  TS_FLAG="--timestamp"
  RUNTIME=( --options runtime )
else
  # Match the identity that signed the outer app so helpers share its chain.
  CERT_DIR="$(mktemp -d)"
  codesign -d --extract-certificates="$CERT_DIR/cert" "$APP_PATH" 2>/dev/null || true
  SIGN_ID=""
  if [[ -f "$CERT_DIR/cert0" ]]; then
    SIGN_ID="$(openssl x509 -inform DER -in "$CERT_DIR/cert0" -noout -fingerprint -sha1 2>/dev/null \
        | sed -e 's/^SHA1 Fingerprint=//' -e 's/://g' || true)"
  fi
  rm -rf "$CERT_DIR"
  TS_FLAG="--timestamp=none"
  RUNTIME=()
fi

if [[ -n "$SIGN_ID" ]]; then
  echo "▸ Re-signing bundled helpers with: $SIGN_ID"
  # opencode + uv: runtime + disable-library-validation.
  for BIN in "$V/opencode/opencode" "$V/uv/uv"; do
    if [[ -f "$BIN" && -f "$HELPER_ENT" ]]; then
      codesign --force --sign "$SIGN_ID" "${RUNTIME[@]}" --entitlements "$HELPER_ENT" "$TS_FLAG" "$BIN" 2>&1 | sed 's/^/    /'
    fi
  done
  if [[ -f "$V/fff/libfff_c.dylib" ]]; then
    codesign --force --sign "$SIGN_ID" "${RUNTIME[@]}" "$TS_FLAG" "$V/fff/libfff_c.dylib" 2>&1 | sed 's/^/    /'
  fi
  if [[ -f "$V/fff/fff-mcp" ]]; then
    codesign --force --sign "$SIGN_ID" "${RUNTIME[@]}" "$TS_FLAG" "$V/fff/fff-mcp" 2>&1 | sed 's/^/    /'
  fi
  # The opencode-fff plugin bundles native node addons (.node) plus a dylib
  # deep inside its npm node_modules (@ff-labs/fff-bin, @yuuang/ffi-rs,
  # @msgpackr-extract, …). Each Mach-O must be Developer-ID signed with a
  # secure timestamp or notarization rejects the whole archive. Sign every
  # nested native binary inside-out, before the outer app is sealed.
  if [[ -d "$V/opencode-fff" ]]; then
    echo "▸ Re-signing opencode-fff native binaries…"
    while IFS= read -r MACHO; do
      [[ -n "$MACHO" ]] || continue
      codesign --force --sign "$SIGN_ID" "${RUNTIME[@]}" "$TS_FLAG" "$MACHO" 2>&1 | sed 's/^/    /' || echo "    ⚠ failed: $MACHO"
    done < <(find "$V/opencode-fff" -type f \( -name '*.node' -o -name '*.dylib' -o -name '*.so' \) 2>/dev/null)
  fi
  # Sparkle's nested helpers arrive ad-hoc signed from SwiftPM. Notarization
  # requires each Mach-O to be signed by our Developer ID identity with a
  # secure timestamp before the framework and outer app are sealed.
  SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  if [[ -d "$SPARKLE_FW" ]]; then
    echo "▸ Re-signing Sparkle nested helpers…"
    for SPARKLE_ITEM in \
      "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
      "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
      "$SPARKLE_FW/Versions/B/Updater.app" \
      "$SPARKLE_FW/Versions/B/Autoupdate"; do
      [[ -e "$SPARKLE_ITEM" ]] || continue
      codesign --force --sign "$SIGN_ID" "${RUNTIME[@]}" "$TS_FLAG" "$SPARKLE_ITEM" 2>&1 | sed 's/^/    /' || echo "    ⚠ failed: $SPARKLE_ITEM"
    done
    codesign --force --sign "$SIGN_ID" "${RUNTIME[@]}" "$TS_FLAG" "$SPARKLE_FW" 2>&1 | sed 's/^/    /' || echo "    ⚠ failed: $SPARKLE_FW"
  fi
  # Re-seal the outer app so the modified helpers are covered. Expand the
  # $(AppIdentifierPrefix) macro in the entitlements (codesign won't).
  OUTER_ENT="$(mktemp -t outer-ent.XXXXXX.plist)"
  sed "s|\$(AppIdentifierPrefix)|${DEV_TEAM}.|g" \
      "$REPO_ROOT/apple/ClawdmeterMac/ClawdmeterMac-Release.entitlements" > "$OUTER_ENT"
  codesign --force --sign "$SIGN_ID" "${RUNTIME[@]}" --entitlements "$OUTER_ENT" "$TS_FLAG" "$APP_PATH" 2>&1 | sed 's/^/    /'
  rm -f "$OUTER_ENT"
else
  echo "✗ Could not determine a signing identity for helper re-signing." >&2
  exit 1
fi

codesign --verify --deep --strict "$APP_PATH" 2>&1 | head -3

# ────────────────────────────────────────────────────────────────────────
# 7. (Optional) staple the bare app bundle. The distributable artifact is the
#    DMG, so the required release gate is DMG notarization + stapling below.
#    Keep app-bundle notarization opt-in because Apple's app-only queue can lag
#    while the DMG queue still completes normally.
# ────────────────────────────────────────────────────────────────────────

if [[ "$SIGN_MODE" == "developerid" && $NOTARIZE_READY == 1 && "${CLAWDMETER_SKIP_BUILD_SCRIPT_NOTARIZATION:-0}" != "1" && "${CLAWDMETER_NOTARIZE_APP_BUNDLE:-0}" == "1" ]]; then
  echo "▸ Notarizing the app bundle (so the ticket can be stapled to it)…"
  APP_ZIP="$BUILD_DIR/${APP_NAME}-app.zip"
  /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
  if xcrun notarytool submit "$APP_ZIP" \
       --key "$ASC_KEY_FILE" --key-id "$CLAWDMETER_ASC_KEY_ID" \
       --issuer "$CLAWDMETER_ASC_ISSUER_ID" --wait 2>&1 | tee "$BUILD_DIR/notarize-app.log" | grep -q "status: Accepted"; then
    xcrun stapler staple "$APP_PATH" 2>&1 | sed 's/^/    /'
  else
    echo "✗ app notarization not Accepted — see $BUILD_DIR/notarize-app.log" >&2
    exit 1
  fi
  rm -f "$APP_ZIP"
elif [[ "$SIGN_MODE" == "developerid" && $NOTARIZE_READY == 1 ]]; then
  echo "▸ Skipping bare app notarization (DMG notarization is the release gate)."
fi

# ────────────────────────────────────────────────────────────────────────
# 7b. Flat Sparkle archive from the (now stapled) .app — the auto-update
#     enclosure. ditto -c -k --keepParent puts Continuum.app at the archive
#     root, the exact layout Sparkle rebuilds when applying a binary delta.
#     Must come AFTER step 7's re-seal/staple so CodeResources + the stapled
#     ticket match the sealed bundle, and BEFORE step 8 mutates the staging copy.
# ────────────────────────────────────────────────────────────────────────

SPARKLE_ZIP="$DIST_DIR/${APP_NAME}-${VERSION}-arm64.${CLAWDMETER_SPARKLE_ARCHIVE_EXT:-zip}"
rm -f "$SPARKLE_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$SPARKLE_ZIP"
echo "✓ Sparkle archive: $SPARKLE_ZIP ($(du -h "$SPARKLE_ZIP" | awk '{print $1}'))"
if [[ "$SIGN_MODE" == "developerid" && "${CLAWDMETER_NOTARIZE_APP_BUNDLE:-0}" != "1" ]]; then
  echo "⚠ Sparkle archive built from an UN-stapled app (CLAWDMETER_NOTARIZE_APP_BUNDLE!=1);" >&2
  echo "  delta-updated installs may hit offline Gatekeeper friction. Release path sets it to 1." >&2
fi

# ────────────────────────────────────────────────────────────────────────
# 8. Stage + build the DMG
# ────────────────────────────────────────────────────────────────────────

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/INSTALL.txt" <<README
Continuum for Mac
=================

1. Drag Continuum.app into the Applications folder.
2. If you have an older /Applications/Clawdmeter.app, drag it to the Trash —
   it's the previous name of the same app; your data carries over.
3. Launch Continuum from Applications. $([[ "$SIGN_MODE" == developerid ]] && echo "It's notarized by Montauk Analytics Inc, so it opens with no warning." || echo "First launch: right-click → Open (un-notarized dev build).")
4. The Continuum icon appears in the menu bar.

Source + iOS/watch apps: https://github.com/darshanbathija/Clawdmeter
README

echo "▸ Building DMG…"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov \
  -format UDZO -imagekey zlib-level=9 "$DMG_PATH" >/dev/null

if [[ "$SIGN_MODE" == "developerid" ]]; then
  echo "▸ Signing DMG…"
  codesign --force --sign "$DEVID_ID" --timestamp "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

echo "✓ DMG: $DMG_PATH ($(du -h "$DMG_PATH" | awk '{print $1}'))"

# ────────────────────────────────────────────────────────────────────────
# 9. (Developer ID + notarize) notarize + staple the DMG container itself.
# ────────────────────────────────────────────────────────────────────────

if [[ "$SIGN_MODE" == "developerid" && $NOTARIZE_READY == 1 && "${CLAWDMETER_SKIP_BUILD_SCRIPT_NOTARIZATION:-0}" != "1" ]]; then
  echo "▸ Notarizing the DMG (Apple notary service, ~2-5 min)…"
  if xcrun notarytool submit "$DMG_PATH" \
       --key "$ASC_KEY_FILE" --key-id "$CLAWDMETER_ASC_KEY_ID" \
       --issuer "$CLAWDMETER_ASC_ISSUER_ID" --wait 2>&1 | tee "$BUILD_DIR/notarize-dmg.log" | grep -q "status: Accepted"; then
    xcrun stapler staple "$DMG_PATH" 2>&1 | sed 's/^/    /'
    echo "✓ DMG notarized + stapled"
  else
    echo "✗ DMG notarization not Accepted — see $BUILD_DIR/notarize-dmg.log" >&2
    exit 1
  fi
elif [[ "$SIGN_MODE" == "developerid" && "${CLAWDMETER_SKIP_BUILD_SCRIPT_NOTARIZATION:-0}" == "1" ]]; then
  echo "▸ Skipping build-script DMG notarization; release-mac.sh owns the notarization gate."
elif [[ "$SIGN_MODE" == "developerid" ]]; then
  echo "✗ Developer ID signed but NOT notarized." >&2
  exit 1
fi

# ────────────────────────────────────────────────────────────────────────
# 10. Verify the DMG mounts + the app is accepted by Gatekeeper
# ────────────────────────────────────────────────────────────────────────

echo "▸ Verifying DMG…"
MOUNT_POINT=$(hdiutil attach -nobrowse -readonly "$DMG_PATH" 2>&1 | grep -o '/Volumes/[^ ]*' | head -1)
[[ -n "$MOUNT_POINT" ]] || { echo "✗ DMG did not mount"; exit 1; }
cleanup_mount() { hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true; }
trap cleanup_mount EXIT
if [[ -d "$MOUNT_POINT/${APP_NAME}.app" ]]; then
  echo "✓ DMG mounts and contains ${APP_NAME}.app"
  codesign --verify --deep --strict "$MOUNT_POINT/${APP_NAME}.app" 2>&1 | head -2
  if [[ "$SIGN_MODE" == "developerid" ]]; then
    # spctl exits non-zero for an un-notarized app, and under `set -o
    # pipefail` the old `spctl … | head` form killed the whole release the
    # first time the deferred-notarization mode actually ran: release-mac.sh
    # invokes this script with CLAWDMETER_SKIP_BUILD_SCRIPT_NOTARIZATION=1
    # and notarizes the DMG itself AFTERWARDS, so "Unnotarized Developer ID"
    # is the expected state here. Only treat rejection as fatal when this
    # script owned notarization (i.e. the app should already be accepted).
    SPCTL_OUT="$(spctl -a -vvv -t exec "$MOUNT_POINT/${APP_NAME}.app" 2>&1 || true)"
    printf '%s\n' "$SPCTL_OUT" | head -2
    if [[ "${CLAWDMETER_SKIP_BUILD_SCRIPT_NOTARIZATION:-0}" == "1" ]]; then
      echo "  (Gatekeeper acceptance is gated on release-mac.sh's DMG notarization step)"
    elif ! printf '%s\n' "$SPCTL_OUT" | grep -q "accepted"; then
      echo "✗ Gatekeeper rejected ${APP_NAME}.app after in-script notarization" >&2
      exit 1
    fi
  fi
else
  echo "✗ DMG mounted but no ${APP_NAME}.app inside"
  exit 1
fi
hdiutil detach "$MOUNT_POINT" -quiet
trap - EXIT

DMG_MB=$(( $(stat -f%z "$DMG_PATH") / 1024 / 1024 ))
echo "✓ DMG size ${DMG_MB}MB"
echo ""
echo "✅ Done."
echo "   $DMG_PATH"
