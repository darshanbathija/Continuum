#!/usr/bin/env bash
# Single Mac release path for Continuum Sparkle updates.
#
# Required local credentials:
#   CLAWDMETER_RELEASE_SIGNING_IDENTITY  Developer ID Application identity or SHA-1 hash
#   CLAWDMETER_SPARKLE_PUBLIC_ED_KEY     public EdDSA key from Sparkle generate_keys
# Optional env:
#   CLAWDMETER_TEAM_ID                   expected Apple team id
#   CLAWDMETER_NOTARY_PROFILE            keychain profile, default clawdmeter-notary
#   CLAWDMETER_SPARKLE_KEY_ACCOUNT       Sparkle keychain account, default clawdmeter-mac-release
#   SPARKLE_BIN_DIR                      directory containing generate_appcast/sign_update/generate_keys
#   CLAWDMETER_ASC_KEY_PATH              App Store Connect API private key, if using ASC-backed provisioning
#   CLAWDMETER_ASC_KEY_ID                App Store Connect API key id
#   CLAWDMETER_ASC_ISSUER_ID             App Store Connect issuer id

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/tools/release-config.sh"

MODE="publish"
VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --validate-only) MODE="validate"; shift ;;
    --no-publish) MODE="no-publish"; shift ;;
    --publish) MODE="publish"; shift ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '1,18p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "✗ $*" >&2; exit 1; }
ok() { echo "✓ $*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

project_value() {
  local key="$1"
  awk -F': ' -v key="$key" '$1 ~ key {gsub(/"/, "", $2); gsub(/[[:space:]]/, "", $2); print $2; exit}' apple/project.yml
}

project_team_id() {
  awk -F': ' '/DEVELOPMENT_TEAM:/ {gsub(/"/, "", $2); gsub(/[[:space:]]/, "", $2); print $2; exit}' apple/project.yml
}

find_identity_line() {
  local identity="$1"
  security find-identity -p codesigning -v | awk -v identity="$identity" 'index($0, identity) {print; exit}'
}

identity_team_id() {
  sed -nE 's/.*\(([A-Z0-9]{10})\)".*/\1/p'
}

extract_sparkle_public_key() {
  awk '
    /^[[:space:]]*[A-Za-z0-9+\/=]{20,}[[:space:]]*$/ {
      gsub(/[[:space:]]/, "")
      print
      exit
    }
    /SUPublicEDKey/ {
      if (match($0, /[A-Za-z0-9+\/=]{20,}/)) {
        print substr($0, RSTART, RLENGTH)
        exit
      }
    }
  '
}

find_sparkle_tool() {
  local tool="$1"
  if [[ -n "${SPARKLE_BIN_DIR:-}" && -x "$SPARKLE_BIN_DIR/$tool" ]]; then
    printf '%s\n' "$SPARKLE_BIN_DIR/$tool"
    return 0
  fi
  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
    return 0
  fi
  local derived
  derived="$(find "${HOME}/Library/Developer/Xcode/DerivedData" \
    -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin/${tool}" \
    -perm +111 \
    -print 2>/dev/null | head -n1 || true)"
  if [[ -n "$derived" ]]; then
    printf '%s\n' "$derived"
    return 0
  fi
  return 1
}

verify_static_config() {
  local project_min_os info_min_os info_public_key marketing build project_team
  project_min_os="$(awk -F': ' '/MACOSX_DEPLOYMENT_TARGET:/ {gsub(/"/, "", $2); gsub(/[[:space:]]/, "", $2); print $2; exit}' apple/project.yml)"
  marketing="$(project_value MARKETING_VERSION)"
  build="$(project_value CURRENT_PROJECT_VERSION)"
  project_team="$(project_team_id)"
  info_min_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' apple/ClawdmeterMac/Info.plist)"
  info_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' apple/ClawdmeterMac/Info.plist)"

  [[ -n "$marketing" ]] || die "MARKETING_VERSION missing from apple/project.yml"
  [[ -n "$build" ]] || die "CURRENT_PROJECT_VERSION missing from apple/project.yml"
  [[ -n "$project_team" ]] || die "DEVELOPMENT_TEAM missing from apple/project.yml"
  [[ -z "${CLAWDMETER_TEAM_ID:-}" || "$CLAWDMETER_TEAM_ID" == "$project_team" ]] || die "CLAWDMETER_TEAM_ID $CLAWDMETER_TEAM_ID does not match project team $project_team"
  [[ "$CLAWDMETER_MAC_MIN_OS" == "$project_min_os" ]] || die "release-config min OS $CLAWDMETER_MAC_MIN_OS != project $project_min_os"
  [[ "$info_min_os" == '$(MACOSX_DEPLOYMENT_TARGET)' || "$info_min_os" == "$project_min_os" ]] || die "Info.plist LSMinimumSystemVersion is $info_min_os, expected project deployment target"
  [[ "$info_public_key" == '$(SPARKLE_PUBLIC_ED_KEY)' || "$info_public_key" == "${CLAWDMETER_SPARKLE_PUBLIC_ED_KEY:-}" ]] || die "Info.plist SUPublicEDKey does not come from SPARKLE_PUBLIC_ED_KEY"
  /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' apple/ClawdmeterMac/Info.plist | grep -qx "$CLAWDMETER_PAGES_BASE_URL/$CLAWDMETER_APPCAST_PATH" || die "SUFeedURL does not match release config"
  /usr/libexec/PlistBuddy -c 'Print :SUEnableInstallerLauncherService' apple/ClawdmeterMac/Info.plist | grep -qx 'true' || die "Sparkle installer launcher service is not enabled"
  grep -q 'com.apple.security.temporary-exception.mach-lookup.global-name' apple/ClawdmeterMac/ClawdmeterMac-Release.entitlements || die "Sparkle sandbox mach lookup entitlement missing"
  ok "static release config matches project and Info.plist"

  if [[ -z "$VERSION" ]]; then VERSION="$marketing"; fi
  CURRENT_BUILD="$build"
  PROJECT_TEAM_ID="$project_team"
}

verify_credentials() {
  local identity_line identity_team sparkle_output sparkle_public_key
  [[ -n "${CLAWDMETER_RELEASE_SIGNING_IDENTITY:-}" ]] || die "CLAWDMETER_RELEASE_SIGNING_IDENTITY must name a Developer ID Application certificate"
  [[ "$CLAWDMETER_RELEASE_SIGNING_IDENTITY" == *"Developer ID Application"* || "$CLAWDMETER_RELEASE_SIGNING_IDENTITY" =~ ^[A-Fa-f0-9]{40}$ ]] || die "signing identity must be Developer ID Application or a SHA-1 identity"
  identity_line="$(find_identity_line "$CLAWDMETER_RELEASE_SIGNING_IDENTITY")"
  [[ -n "$identity_line" ]] || die "Developer ID identity not found in keychain"
  [[ "$identity_line" == *"Developer ID Application"* ]] || die "resolved signing identity is not a Developer ID Application certificate: $identity_line"
  identity_team="$(printf '%s\n' "$identity_line" | identity_team_id)"
  [[ -n "$identity_team" ]] || die "could not extract Apple team id from signing identity: $identity_line"
  [[ "$identity_team" == "$PROJECT_TEAM_ID" ]] || die "Developer ID team $identity_team does not match project team $PROJECT_TEAM_ID"
  [[ -n "${CLAWDMETER_SPARKLE_PUBLIC_ED_KEY:-}" ]] || die "CLAWDMETER_SPARKLE_PUBLIC_ED_KEY is required"
  [[ "$CLAWDMETER_SPARKLE_PUBLIC_ED_KEY" != *REPLACE* ]] || die "Sparkle public key is still a placeholder"
  sparkle_output="$("$GENERATE_KEYS" --account "$CLAWDMETER_SPARKLE_KEY_ACCOUNT" -p 2>/dev/null)" || die "Sparkle private key not found in keychain account '$CLAWDMETER_SPARKLE_KEY_ACCOUNT'"
  sparkle_public_key="$(printf '%s\n' "$sparkle_output" | extract_sparkle_public_key)"
  [[ -n "$sparkle_public_key" ]] || die "could not read Sparkle public key from keychain account '$CLAWDMETER_SPARKLE_KEY_ACCOUNT'"
  [[ "$sparkle_public_key" == "$CLAWDMETER_SPARKLE_PUBLIC_ED_KEY" ]] || die "Sparkle keychain public key does not match CLAWDMETER_SPARKLE_PUBLIC_ED_KEY"
  xcrun notarytool history --keychain-profile "$CLAWDMETER_NOTARY_PROFILE" >/dev/null || die "notary profile '$CLAWDMETER_NOTARY_PROFILE' is unavailable"
  ok "Developer ID team, Sparkle keypair, and notary profile are available"
}

verify_provisioning_auth() {
  grep -q 'com.apple.security.application-groups' apple/ClawdmeterMac/ClawdmeterMac-Release.entitlements || return 0
  if [[ -z "${CLAWDMETER_ASC_KEY_PATH:-}${CLAWDMETER_ASC_KEY_ID:-}${CLAWDMETER_ASC_ISSUER_ID:-}" ]]; then
    ok "App Store Connect provisioning auth not configured; using installed Developer ID profiles"
    return 0
  fi
  [[ -r "$CLAWDMETER_ASC_KEY_PATH" ]] || die "CLAWDMETER_ASC_KEY_PATH is not readable: $CLAWDMETER_ASC_KEY_PATH"
  [[ -n "${CLAWDMETER_ASC_KEY_ID:-}" ]] || die "CLAWDMETER_ASC_KEY_ID is required for Developer ID provisioning"
  [[ "$CLAWDMETER_ASC_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || die "CLAWDMETER_ASC_KEY_ID does not look like a 10-character Apple key id"
  [[ -n "${CLAWDMETER_ASC_ISSUER_ID:-}" ]] || die "CLAWDMETER_ASC_ISSUER_ID is required for Developer ID provisioning"
  [[ "$CLAWDMETER_ASC_ISSUER_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "CLAWDMETER_ASC_ISSUER_ID does not look like a UUID"
  ok "App Store Connect provisioning auth is configured"
}

profile_file_for_name() {
  local expected_name="$1"
  local profile_dir file tmp name team
  local profile_dirs=(
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    "$HOME/Library/MobileDevice/Provisioning Profiles"
  )
  for profile_dir in "${profile_dirs[@]}"; do
    [[ -d "$profile_dir" ]] || continue
    while IFS= read -r -d '' file; do
      tmp="$(mktemp)"
      if /usr/bin/security cms -D -i "$file" >"$tmp" 2>/dev/null; then
        name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$tmp" 2>/dev/null || true)"
        team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$tmp" 2>/dev/null || true)"
        rm -f "$tmp"
        if [[ "$name" == "$expected_name" && "$team" == "$PROJECT_TEAM_ID" ]]; then
          printf '%s\n' "$file"
          return 0
        fi
      else
        rm -f "$tmp"
      fi
    done < <(find "$profile_dir" -maxdepth 1 -type f \( -name '*.provisionprofile' -o -name '*.mobileprovision' \) -print0 2>/dev/null)
  done
  return 1
}

verify_developer_id_profiles() {
  [[ -n "${CLAWDMETER_MAC_PROFILE_NAME:-}" ]] || die "CLAWDMETER_MAC_PROFILE_NAME is required"
  [[ -n "${CLAWDMETER_MAC_WIDGET_PROFILE_NAME:-}" ]] || die "CLAWDMETER_MAC_WIDGET_PROFILE_NAME is required"
  profile_file_for_name "$CLAWDMETER_MAC_PROFILE_NAME" >/dev/null || die "Developer ID profile not installed: $CLAWDMETER_MAC_PROFILE_NAME"
  profile_file_for_name "$CLAWDMETER_MAC_WIDGET_PROFILE_NAME" >/dev/null || die "Developer ID profile not installed: $CLAWDMETER_MAC_WIDGET_PROFILE_NAME"
  ok "Developer ID direct provisioning profiles are installed"
}

verify_tools() {
  need xcodebuild
  need xcrun
  need codesign
  need spctl
  need hdiutil
  need curl
  need gh
  need git
  need python3
  GENERATE_APPCAST="$(find_sparkle_tool generate_appcast)" || die "generate_appcast not found; set SPARKLE_BIN_DIR to Sparkle/bin"
  SIGN_UPDATE="$(find_sparkle_tool sign_update)" || die "sign_update not found; set SPARKLE_BIN_DIR to Sparkle/bin"
  GENERATE_KEYS="$(find_sparkle_tool generate_keys)" || die "generate_keys not found; set SPARKLE_BIN_DIR to Sparkle/bin"
  export GENERATE_APPCAST SIGN_UPDATE GENERATE_KEYS
  gh auth status >/dev/null || die "GitHub CLI is not authenticated"
  ok "release tooling is available"
}

verify_pages_configuration() {
  local source
  source="$(gh api "repos/${CLAWDMETER_RELEASE_OWNER}/${CLAWDMETER_RELEASE_REPO}/pages" \
    --jq '(.source.branch // "") + ":" + (.source.path // "")' 2>/dev/null || true)"
  [[ "$source" == "${CLAWDMETER_PAGES_BRANCH}:/" ]] || die "GitHub Pages source is '$source', expected '${CLAWDMETER_PAGES_BRANCH}:/' so the appcast mirror reaches the live Sparkle URL"
  ok "GitHub Pages source is ${CLAWDMETER_PAGES_BRANCH}:/"
}

verify_feed_preconditions() {
  local notes="docs/${CLAWDMETER_RELEASE_NOTES_PATH}/${VERSION}.md"
  [[ -f "$notes" ]] || die "release notes missing at $notes"
  [[ -s "$notes" ]] || die "release notes file is empty: $notes"
  mkdir -p "docs/$(dirname "$CLAWDMETER_APPCAST_PATH")" "docs/$CLAWDMETER_RELEASE_NOTES_PATH"
  ok "release notes are ready"
}

verify_publish_git_preconditions() {
  local branch
  branch="$(git branch --show-current)"
  [[ "$branch" == "main" ]] || die "publish mode must run from main so GitHub Pages publishes atomically; current branch is '$branch'"
  git diff --quiet || die "working tree has unstaged changes before release publish"
  git diff --cached --quiet || die "index has staged changes before release publish"
  [[ -z "$(git ls-files --others --exclude-standard)" ]] || die "working tree has untracked files before release publish"
  git fetch origin main >/dev/null 2>&1 || die "could not fetch origin/main"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main is not up to date with origin/main"
  ok "publish git preconditions passed"
}

publish_asset() {
  local tag="$1" dmg="$2" notes="$3"
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$dmg" --clobber
  else
    gh release create "$tag" "$dmg" \
      --title "${CLAWDMETER_APP_NAME} ${VERSION}" \
      --notes-file "$notes" \
      --latest
  fi
  ok "GitHub release asset uploaded for $tag"
}

verify_asset_url() {
  local url="$1" expected_size="$2"
  local headers content_length
  headers="$(curl -fsSIL "$url")"
  content_length="$(printf '%s\n' "$headers" | awk 'BEGIN{IGNORECASE=1} /^content-length:/ {gsub("\r", "", $2); value=$2} END{print value}')"
  [[ -n "$content_length" ]] || die "asset URL has no content-length: $url"
  [[ "$content_length" == "$expected_size" ]] || die "asset byte length mismatch: url=$content_length local=$expected_size"
  ok "asset URL and byte length verified"
}

update_release_history() {
  local tag="$1" dmg="$2"
  local history_path="docs/${CLAWDMETER_RELEASE_HISTORY_PATH}"
  local dmg_name notes_public_name notes_url published_at
  dmg_name="$(basename "$dmg")"
  notes_public_name="${dmg_name%.*}.md"
  notes_url="${CLAWDMETER_PAGES_BASE_URL}/${CLAWDMETER_RELEASE_NOTES_PATH}/${notes_public_name}"
  published_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  mkdir -p "$(dirname "$history_path")"
  python3 - "$history_path" "$VERSION" "$CURRENT_BUILD" "${CLAWDMETER_APP_NAME} ${VERSION}" "$published_at" "$notes_url" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
entry = {
    "version": sys.argv[2],
    "build": sys.argv[3],
    "title": sys.argv[4],
    "publishedAt": sys.argv[5],
    "notesURL": sys.argv[6],
}
try:
    data = json.loads(path.read_text())
    if not isinstance(data, list):
        data = []
except FileNotFoundError:
    data = []

data = [row for row in data if row.get("version") != entry["version"]]
data.insert(0, entry)
path.write_text(json.dumps(data, indent=2) + "\n")
PY
  ok "release history updated for $tag"
}

# Extract the Sparkle archive and prove the app inside is the one Sparkle will
# reconstruct after applying a binary delta: a valid code signature, and (publish
# only) a stapled notarization ticket that passes offline Gatekeeper. A zip of an
# un-stapled app delta-updates into Gatekeeper friction, so fail here, not on users.
verify_sparkle_archive_stapled() {
  local zip="$1" tmp app
  tmp="$(mktemp -d)"
  /usr/bin/ditto -x -k "$zip" "$tmp" || { rm -rf "$tmp"; die "could not extract Sparkle archive $zip"; }
  app="$tmp/${CLAWDMETER_APP_NAME}.app"
  [[ -d "$app" ]] || { rm -rf "$tmp"; die "Sparkle archive missing ${CLAWDMETER_APP_NAME}.app at its root"; }
  if ! codesign --verify --deep --strict "$app" 2>/dev/null; then
    rm -rf "$tmp"; die "Sparkle archive app fails codesign --verify"
  fi
  if [[ "$MODE" == "publish" ]]; then
    xcrun stapler validate "$app" >/dev/null 2>&1 \
      || { rm -rf "$tmp"; die "Sparkle archive app is not stapled; rebuild with CLAWDMETER_NOTARIZE_APP_BUNDLE=1"; }
    spctl --assess --type exec "$app" >/dev/null 2>&1 \
      || { rm -rf "$tmp"; die "Sparkle archive app rejected by Gatekeeper (spctl)"; }
  fi
  rm -rf "$tmp"
  ok "Sparkle archive verified ($(basename "$zip"))"
}

# Download the newest prior Sparkle archives from the feed release so
# generate_appcast can diff against them. Tolerant of a missing feed (first run →
# no baselines → no deltas) and of zero matching assets.
hydrate_feed_baselines() {
  local stage="$1"
  if ! gh release view "$FEED_TAG" >/dev/null 2>&1; then
    ok "feed release $FEED_TAG does not exist yet — first run, no deltas"
    return 0
  fi
  # Seed the prior appcast so generate_appcast preserves already-signed items it
  # has no archive for (e.g. older DMG entries during the DMG→zip transition).
  if [[ -f "docs/${CLAWDMETER_APPCAST_PATH}" ]]; then
    cp "docs/${CLAWDMETER_APPCAST_PATH}" "$stage/appcast.xml"
  fi
  local ext="$CLAWDMETER_SPARKLE_ARCHIVE_EXT" assets keep name
  assets="$(gh release view "$FEED_TAG" --json assets \
    --jq ".assets[].name | select(endswith(\".${ext}\"))" 2>/dev/null || true)"
  if [[ -z "$assets" ]]; then
    ok "feed release has no prior $ext archives yet"
    return 0
  fi
  # Newest CLAWDMETER_SPARKLE_FEED_KEEP versions, excluding this version's own
  # archive (a re-run must not diff a version against itself). Portable numeric
  # semver sort — do not depend on `sort -V`.
  keep="$(printf '%s\n' "$assets" \
    | grep -v -- "-${VERSION}-arm64\.${ext}\$" \
    | sed -E 's/.*-([0-9]+)\.([0-9]+)\.([0-9]+)-arm64\..*/\1 \2 \3 &/' \
    | sort -k1,1nr -k2,2nr -k3,3nr \
    | awk '{print $4}' \
    | head -n "$CLAWDMETER_SPARKLE_FEED_KEEP")"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    gh release download "$FEED_TAG" --pattern "$name" --dir "$stage" --clobber \
      || die "could not download baseline archive $name from $FEED_TAG"
    ok "hydrated baseline $name"
  done <<< "$keep"
}

# Upload the new full archive + every generated delta to the single stable feed
# release. Create it on first run with --latest=false so the per-version DMG
# release keeps /releases/latest. --clobber makes re-runs idempotent.
upload_feed_assets() {
  local stage="$1" zip_name="$2" d had_delta=0
  if ! gh release view "$FEED_TAG" >/dev/null 2>&1; then
    gh release create "$FEED_TAG" \
      --title "$CLAWDMETER_SPARKLE_FEED_TITLE" \
      --notes "Sparkle auto-update feed for Continuum Mac: .${CLAWDMETER_SPARKLE_ARCHIVE_EXT} app archives + binary deltas referenced by updates/appcast.xml. Managed by tools/release-mac.sh — do not delete." \
      --latest=false \
      || die "could not create feed release $FEED_TAG"
    ok "created feed release $FEED_TAG"
  fi
  gh release upload "$FEED_TAG" "$stage/$zip_name" --clobber \
    || die "could not upload $zip_name to $FEED_TAG"
  shopt -s nullglob
  for d in "$stage"/*.delta; do
    gh release upload "$FEED_TAG" "$d" --clobber \
      || die "could not upload $(basename "$d") to $FEED_TAG"
    had_delta=1
  done
  shopt -u nullglob
  if [[ "$had_delta" -eq 1 ]]; then
    ok "uploaded archive + delta(s) to $FEED_TAG"
  else
    ok "uploaded archive to $FEED_TAG (no deltas this release)"
  fi
}

# Keep the feed release in sync with the freshly generated appcast: survivors are
# exactly the top-level archives + deltas left in the stage dir (generate_appcast
# moves pruned full archives into old_updates/). Any feed asset not among them —
# an aged-out version's archive and ALL its stale deltas — is deleted together.
prune_feed_assets() {
  local stage="$1" ext="$CLAWDMETER_SPARKLE_ARCHIVE_EXT" survivors existing name
  survivors="$(cd "$stage" && ls -1 -- *."$ext" *.delta 2>/dev/null || true)"
  existing="$(gh release view "$FEED_TAG" --json assets \
    --jq ".assets[].name | select(endswith(\".${ext}\") or endswith(\".delta\"))" 2>/dev/null || true)"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if ! printf '%s\n' "$survivors" | grep -qxF -- "$name"; then
      if gh release delete-asset "$FEED_TAG" "$name" --yes 2>/dev/null; then
        ok "pruned stale feed asset $name"
      else
        echo "⚠ could not delete stale feed asset $name" >&2
      fi
    fi
  done <<< "$existing"
}

generate_pages_appcast() {
  local zip="$1"
  local stage=".build/sparkle-appcast/$FEED_TAG"
  local ext="$CLAWDMETER_SPARKLE_ARCHIVE_EXT"
  local zip_name notes_public_name arch base
  zip_name="$(basename "$zip")"
  notes_public_name="${zip_name%.${ext}}.md"
  rm -rf "$stage"
  mkdir -p "$stage"

  hydrate_feed_baselines "$stage"
  cp "$zip" "$stage/"
  cp "docs/${CLAWDMETER_RELEASE_NOTES_PATH}/${VERSION}.md" "$stage/$notes_public_name"

  # Re-attach release notes for every staged archive (new + hydrated baselines)
  # so generate_appcast keeps each item's <sparkle:releaseNotesLink>. Notes are
  # matched to archives by basename in the same directory.
  shopt -s nullglob
  for arch in "$stage"/*."$ext"; do
    base="$(basename "${arch%.*}")"
    [[ -f "$stage/${base}.md" ]] && continue
    [[ -f "docs/${CLAWDMETER_RELEASE_NOTES_PATH}/${base}.md" ]] \
      && cp "docs/${CLAWDMETER_RELEASE_NOTES_PATH}/${base}.md" "$stage/${base}.md" || true
  done
  shopt -u nullglob

  "$GENERATE_APPCAST" \
    --account "$CLAWDMETER_SPARKLE_KEY_ACCOUNT" \
    --maximum-deltas "$CLAWDMETER_SPARKLE_MAX_DELTAS" \
    --maximum-versions "$CLAWDMETER_SPARKLE_FEED_KEEP" \
    --download-url-prefix "https://github.com/${CLAWDMETER_RELEASE_OWNER}/${CLAWDMETER_RELEASE_REPO}/releases/download/${FEED_TAG}/" \
    --release-notes-url-prefix "${CLAWDMETER_PAGES_BASE_URL}/${CLAWDMETER_RELEASE_NOTES_PATH}/" \
    "$stage"

  [[ -f "$stage/appcast.xml" ]] || die "generate_appcast did not create appcast.xml"

  if [[ "$MODE" == "publish" ]]; then
    upload_feed_assets "$stage" "$zip_name"
    prune_feed_assets "$stage"
  else
    ok "skipping feed upload/prune (--no-publish)"
  fi

  cp "$stage/appcast.xml" "docs/${CLAWDMETER_APPCAST_PATH}"
  cp "$stage/$notes_public_name" "docs/${CLAWDMETER_RELEASE_NOTES_PATH}/$notes_public_name"
  grep -q "sparkle:edSignature" "docs/${CLAWDMETER_APPCAST_PATH}" || die "appcast is missing Sparkle edSignature"
  grep -q "$CLAWDMETER_MAC_MIN_OS" "docs/${CLAWDMETER_APPCAST_PATH}" || die "appcast is missing minimum OS $CLAWDMETER_MAC_MIN_OS"
  grep -q "<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>" "docs/${CLAWDMETER_APPCAST_PATH}" \
    || die "appcast newest item is not $VERSION"
  update_release_history "$FEED_TAG" "$zip"
  ok "GitHub Pages appcast generated at docs/${CLAWDMETER_APPCAST_PATH} ($(grep -c '<item>' "docs/${CLAWDMETER_APPCAST_PATH}") item(s))"
}

publish_pages_feed() {
  local tag="$1"
  git add "docs/${CLAWDMETER_APPCAST_PATH}" "docs/${CLAWDMETER_RELEASE_NOTES_PATH}" "docs/${CLAWDMETER_RELEASE_HISTORY_PATH}"
  if git diff --cached --quiet; then
    ok "GitHub Pages feed unchanged"
  else
    git commit -m "release: publish Mac appcast $tag"
    ok "GitHub Pages feed committed for $tag"
  fi
  git push origin main
  ok "GitHub Pages feed pushed to origin/main"
}

verify_live_appcast() {
  local tag="$1" expected_version="$2" expected_build="$3" expected_asset_url="$4"
  local public_url="${CLAWDMETER_PAGES_BASE_URL}/${CLAWDMETER_APPCAST_PATH}"
  local attempts="${CLAWDMETER_LIVE_APPCAST_RETRIES:-60}"
  local sleep_seconds="${CLAWDMETER_LIVE_APPCAST_SLEEP_SECONDS:-10}"
  local attempt feed

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    feed="$(curl -fsSL "${public_url}?tag=${tag}&attempt=${attempt}&ts=$(date +%s)" 2>/dev/null || true)"
    if printf '%s\n' "$feed" | grep -q "<sparkle:shortVersionString>${expected_version}</sparkle:shortVersionString>" \
      && printf '%s\n' "$feed" | grep -q "<sparkle:version>${expected_build}</sparkle:version>" \
      && printf '%s\n' "$feed" | grep -Fq "$expected_asset_url" \
      && printf '%s\n' "$feed" | grep -q "sparkle:edSignature"; then
      ok "live Sparkle appcast advertises ${expected_version} build ${expected_build}"
      return 0
    fi
    if [[ "$attempt" -lt "$attempts" ]]; then
      sleep "$sleep_seconds"
    fi
  done

  die "live appcast did not advertise ${expected_version} build ${expected_build} after $((attempts * sleep_seconds)) seconds: $public_url"
}

notarize_and_verify_dmg() {
  local dmg="$1"
  local timeout="${CLAWDMETER_NOTARY_TIMEOUT:-30m}"
  local log_dir=".build/notary"
  local log_path="$log_dir/$(basename "${dmg%.dmg}").notarytool.log"
  local status=0
  local submission_id=""
  if xcrun stapler validate "$dmg" >/dev/null 2>&1; then
    ok "DMG already stapled"
  else
    mkdir -p "$log_dir"
    set +e
    xcrun notarytool submit "$dmg" \
      --keychain-profile "$CLAWDMETER_NOTARY_PROFILE" \
      --wait \
      --timeout "$timeout" \
      2>&1 | tee "$log_path"
    status="${PIPESTATUS[0]}"
    set -e
    submission_id="$(awk '/^[[:space:]]*id:/ {print $2; exit}' "$log_path")"
    if [[ "$status" -ne 0 ]]; then
      if [[ -n "$submission_id" ]]; then
        xcrun notarytool info "$submission_id" --keychain-profile "$CLAWDMETER_NOTARY_PROFILE" || true
        xcrun notarytool log "$submission_id" --keychain-profile "$CLAWDMETER_NOTARY_PROFILE" "$log_path.json" || true
      fi
      die "DMG notarization failed or did not complete within $timeout; see $log_path"
    fi
    grep -q 'status: Accepted' "$log_path" || die "DMG notarization did not return Accepted; see $log_path"
    xcrun stapler staple "$dmg"
  fi
  spctl --assess --type open --context context:primary-signature "$dmg"
  ok "DMG notarized, stapled, and accepted by spctl"
}

export_release_env() {
  export CLAWDMETER_RELEASE_OWNER
  export CLAWDMETER_RELEASE_REPO
  export CLAWDMETER_APP_NAME
  export CLAWDMETER_BUNDLE_ID
  export CLAWDMETER_RELEASE_TAG_PREFIX
  export CLAWDMETER_RELEASE_TAG_SUFFIX
  export CLAWDMETER_RELEASE_ASSET_PREFIX
  export CLAWDMETER_PAGES_BASE_URL
  export CLAWDMETER_PAGES_BRANCH
  export CLAWDMETER_APPCAST_PATH
  export CLAWDMETER_RELEASE_NOTES_PATH
  export CLAWDMETER_RELEASE_HISTORY_PATH
  export CLAWDMETER_NOTARY_PROFILE
  export CLAWDMETER_MAC_MIN_OS
  export CLAWDMETER_SPARKLE_KEY_ACCOUNT
  export CLAWDMETER_TEAM_ID
  export CLAWDMETER_RELEASE_SIGNING_IDENTITY
  export CLAWDMETER_SPARKLE_PUBLIC_ED_KEY
  export CLAWDMETER_MAC_PROFILE_NAME
  export CLAWDMETER_MAC_WIDGET_PROFILE_NAME
  export CLAWDMETER_SPARKLE_FEED_TAG
  export CLAWDMETER_SPARKLE_FEED_TITLE
  export CLAWDMETER_SPARKLE_FEED_KEEP
  export CLAWDMETER_SPARKLE_MAX_DELTAS
  export CLAWDMETER_SPARKLE_ARCHIVE_EXT
  [[ -z "${CLAWDMETER_ASC_KEY_PATH:-}" ]] || export CLAWDMETER_ASC_KEY_PATH
  [[ -z "${CLAWDMETER_ASC_KEY_ID:-}" ]] || export CLAWDMETER_ASC_KEY_ID
  [[ -z "${CLAWDMETER_ASC_ISSUER_ID:-}" ]] || export CLAWDMETER_ASC_ISSUER_ID
}

verify_static_config
verify_tools
verify_pages_configuration
verify_credentials
verify_provisioning_auth
verify_developer_id_profiles
verify_feed_preconditions

if [[ "$MODE" == "validate" ]]; then
  ok "release validation passed"
  exit 0
fi

if [[ "$MODE" == "publish" ]]; then
  verify_publish_git_preconditions
fi

TAG="${CLAWDMETER_RELEASE_TAG_PREFIX}${VERSION}${CLAWDMETER_RELEASE_TAG_SUFFIX}"
DMG_NAME="${CLAWDMETER_RELEASE_ASSET_PREFIX}-${VERSION}-arm64.dmg"
DMG_PATH="$REPO_ROOT/dist/$DMG_NAME"
NOTES_PATH="docs/${CLAWDMETER_RELEASE_NOTES_PATH}/${VERSION}.md"
ASSET_URL="https://github.com/${CLAWDMETER_RELEASE_OWNER}/${CLAWDMETER_RELEASE_REPO}/releases/download/${TAG}/${DMG_NAME}"

# Sparkle auto-update enclosure: a flat archive of the stapled .app, hosted on the
# stable feed release so binary deltas resolve under one --download-url-prefix.
FEED_TAG="$CLAWDMETER_SPARKLE_FEED_TAG"
ZIP_NAME="${CLAWDMETER_RELEASE_ASSET_PREFIX}-${VERSION}-arm64.${CLAWDMETER_SPARKLE_ARCHIVE_EXT}"
ZIP_PATH="$REPO_ROOT/dist/$ZIP_NAME"
ZIP_ASSET_URL="https://github.com/${CLAWDMETER_RELEASE_OWNER}/${CLAWDMETER_RELEASE_REPO}/releases/download/${FEED_TAG}/${ZIP_NAME}"

export_release_env
# CLAWDMETER_NOTARIZE_APP_BUNDLE=1 notarizes + staples the bare .app so the Sparkle
# archive (and every delta reconstructed from it) passes offline Gatekeeper.
# CLAWDMETER_SKIP_BUILD_SCRIPT_NOTARIZATION=1 still defers DMG notarization to
# notarize_and_verify_dmg below.
CLAWDMETER_RELEASE_HARDENED_RUNTIME=1 \
CLAWDMETER_SKIP_BUILD_SCRIPT_NOTARIZATION=1 \
CLAWDMETER_NOTARIZE_APP_BUNDLE=1 \
./tools/build-mac-dmg.sh
[[ -f "$DMG_PATH" ]] || die "expected DMG missing at $DMG_PATH"
[[ -f "$ZIP_PATH" ]] || die "expected Sparkle archive missing at $ZIP_PATH"

notarize_and_verify_dmg "$DMG_PATH"
verify_sparkle_archive_stapled "$ZIP_PATH"

if [[ "$MODE" == "publish" ]]; then
  publish_asset "$TAG" "$DMG_PATH" "$NOTES_PATH"
  verify_asset_url "$ASSET_URL" "$(stat -f%z "$DMG_PATH")"
else
  ok "skipping GitHub DMG asset publish (--no-publish)"
fi

generate_pages_appcast "$ZIP_PATH"

if [[ "$MODE" == "publish" ]]; then
  verify_asset_url "$ZIP_ASSET_URL" "$(stat -f%z "$ZIP_PATH")"
  publish_pages_feed "$FEED_TAG"
  verify_live_appcast "$TAG" "$VERSION" "$CURRENT_BUILD" "$ZIP_ASSET_URL"
  if gh release view "$FEED_TAG" --json assets --jq '.assets[].name' 2>/dev/null | grep -q '\.delta$'; then
    curl -fsSL "${CLAWDMETER_PAGES_BASE_URL}/${CLAWDMETER_APPCAST_PATH}?ts=$(date +%s)" \
      | grep -q 'sparkle:deltas' || die "feed has deltas but live appcast advertises none"
    ok "live appcast advertises sparkle:deltas"
  fi
else
  ok "skipping GitHub Pages publish (--no-publish)"
fi

cat <<EOF
✓ Mac release artifacts ready
  tag:       $TAG
  dmg:       $DMG_PATH        (website / first-install download, release $TAG)
  archive:   $ZIP_PATH        (Sparkle auto-update enclosure)
  feed:      $FEED_TAG release (Sparkle .${CLAWDMETER_SPARKLE_ARCHIVE_EXT} archives + binary deltas)
  appcast:   docs/${CLAWDMETER_APPCAST_PATH}
  pages:     ${CLAWDMETER_PAGES_BASE_URL}/${CLAWDMETER_APPCAST_PATH}

If a bad feed is published, revert docs/${CLAWDMETER_APPCAST_PATH} on main and
rerun this script after fixing the release notes or artifact.
EOF

# Reclaim stale per-worktree DerivedData left by build-mac-dmg.sh's archive and
# sibling worktree builds. Only removes dirs untouched for >24h; never fails the
# release (already succeeded above).
"$REPO_ROOT/tools/prune-derived-data.sh" || true
