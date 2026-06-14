#!/usr/bin/env bash
# Shared Mac release configuration. Keep these values synchronized with
# apple/ClawdmeterMac/Updates/GitHubReleaseConstants.swift.

CLAWDMETER_RELEASE_OWNER="${CLAWDMETER_RELEASE_OWNER:-darshanbathija}"
CLAWDMETER_RELEASE_REPO="${CLAWDMETER_RELEASE_REPO:-Continuum}"
CLAWDMETER_APP_NAME="${CLAWDMETER_APP_NAME:-Continuum}"
CLAWDMETER_BUNDLE_ID="${CLAWDMETER_BUNDLE_ID:-ai.continuum.mac}"
CLAWDMETER_RELEASE_TAG_PREFIX="${CLAWDMETER_RELEASE_TAG_PREFIX:-v}"
CLAWDMETER_RELEASE_TAG_SUFFIX="${CLAWDMETER_RELEASE_TAG_SUFFIX:--mac}"
CLAWDMETER_RELEASE_ASSET_PREFIX="${CLAWDMETER_RELEASE_ASSET_PREFIX:-Continuum}"
CLAWDMETER_PAGES_BASE_URL="${CLAWDMETER_PAGES_BASE_URL:-https://darshanbathija.github.io/Continuum}"
CLAWDMETER_PAGES_BRANCH="${CLAWDMETER_PAGES_BRANCH:-gh-pages}"
CLAWDMETER_APPCAST_PATH="${CLAWDMETER_APPCAST_PATH:-updates/appcast.xml}"
CLAWDMETER_RELEASE_NOTES_PATH="${CLAWDMETER_RELEASE_NOTES_PATH:-updates/release-notes}"
CLAWDMETER_RELEASE_HISTORY_PATH="${CLAWDMETER_RELEASE_HISTORY_PATH:-updates/history.json}"
CLAWDMETER_NOTARY_PROFILE="${CLAWDMETER_NOTARY_PROFILE:-clawdmeter-notary}"
CLAWDMETER_MAC_MIN_OS="${CLAWDMETER_MAC_MIN_OS:-26.0}"
CLAWDMETER_SPARKLE_KEY_ACCOUNT="${CLAWDMETER_SPARKLE_KEY_ACCOUNT:-clawdmeter-mac-release}"
CLAWDMETER_TEAM_ID="${CLAWDMETER_TEAM_ID:-LRL8MRH6B4}"
CLAWDMETER_RELEASE_SIGNING_IDENTITY="${CLAWDMETER_RELEASE_SIGNING_IDENTITY:-Developer ID Application: Montauk Analytics Inc. (LRL8MRH6B4)}"
CLAWDMETER_SPARKLE_PUBLIC_ED_KEY="${CLAWDMETER_SPARKLE_PUBLIC_ED_KEY:-dA6tbvVkaBnCj16gub64AzmBY+peo39LeTOowaFHRIY=}"
CLAWDMETER_MAC_PROFILE_NAME="${CLAWDMETER_MAC_PROFILE_NAME:-Continuum DeveloperID ai.continuum.mac}"
CLAWDMETER_MAC_WIDGET_PROFILE_NAME="${CLAWDMETER_MAC_WIDGET_PROFILE_NAME:-Continuum DeveloperID ai.continuum.mac.widgets}"

# Sparkle incremental-update feed. Auto-updates ship a .zip of the stapled
# .app (delta-able) instead of the DMG; all archives + binary deltas live under
# one stable GitHub release tag so generate_appcast's single download-url-prefix
# resolves every full + delta enclosure. The per-version v<ver>-mac DMG release
# stays the website/first-install download.
CLAWDMETER_SPARKLE_FEED_TAG="${CLAWDMETER_SPARKLE_FEED_TAG:-mac-updates}"
CLAWDMETER_SPARKLE_FEED_TITLE="${CLAWDMETER_SPARKLE_FEED_TITLE:-Continuum Mac auto-update feed}"
CLAWDMETER_SPARKLE_FEED_KEEP="${CLAWDMETER_SPARKLE_FEED_KEEP:-3}"     # full versions retained on feed + appcast
CLAWDMETER_SPARKLE_MAX_DELTAS="${CLAWDMETER_SPARKLE_MAX_DELTAS:-5}"   # deltas against newest version
CLAWDMETER_SPARKLE_ARCHIVE_EXT="${CLAWDMETER_SPARKLE_ARCHIVE_EXT:-zip}"
