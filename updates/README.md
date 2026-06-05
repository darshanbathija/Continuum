# Continuum Sparkle Updates

GitHub Pages serves the production appcast at:

`https://darshanbathija.github.io/Continuum/updates/appcast.xml`

Use `tools/release-mac.sh` for Mac releases. It validates Developer ID
signing, notarization, Sparkle keys, minimum OS alignment, GitHub release
asset availability, and appcast signatures before writing this directory.
In publish mode it must run from a clean, up-to-date `main` checkout; after
the public GitHub release asset is verified, it commits and pushes the Pages
appcast, copied release notes, and `history.json` together. GitHub Pages is
served from the legacy `gh-pages` branch, so the Pages workflow mirrors
`docs/updates` to `gh-pages/updates` and verifies that the live appcast URL
advertises the released version before the release is complete.
The Pages workflow rejects an empty or unsigned appcast, invalid or stale
`history.json`, appcasts missing the macOS minimum-version marker, and release
notes links that do not resolve to files in `docs/updates/release-notes`.

Required release environment:

- `CLAWDMETER_RELEASE_SIGNING_IDENTITY`: Developer ID Application identity.
- `CLAWDMETER_SPARKLE_PUBLIC_ED_KEY`: public EdDSA key embedded in the app.
- `CLAWDMETER_SPARKLE_KEY_ACCOUNT`: Sparkle keychain account used by
  `generate_keys -p` and `generate_appcast --account` (defaults to
  `clawdmeter-mac-release`).
- `CLAWDMETER_NOTARY_PROFILE`: notarytool keychain profile (defaults to
  `clawdmeter-notary`).
- `CLAWDMETER_ASC_KEY_PATH`: readable App Store Connect API private key used
  by `xcodebuild -allowProvisioningUpdates` for Developer ID App Group
  provisioning profiles and release-Mac device registration.
- `CLAWDMETER_ASC_KEY_ID`: App Store Connect API key id.
- `CLAWDMETER_ASC_ISSUER_ID`: App Store Connect issuer UUID.
- `CLAWDMETER_MAC_PROFILE_NAME`: Developer ID direct provisioning profile for
  `ai.continuum.mac` (defaults to `Continuum DeveloperID ai.continuum.mac`).
- `CLAWDMETER_MAC_WIDGET_PROFILE_NAME`: Developer ID direct provisioning profile
  for `ai.continuum.mac.widgets` (defaults to
  `Continuum DeveloperID ai.continuum.mac.widgets`).

This repo is configured for Montauk Analytics Inc, Apple team
`LRL8MRH6B4`. If a release machine resolves a Developer ID certificate under
another team, stop and write a migration plan before shipping.

Rollback procedure:

1. Revert `docs/updates/appcast.xml` on `main`.
2. Push the revert so the Pages workflow mirrors the previous feed to
   `gh-pages/updates/appcast.xml`.
3. If the release asset is bad, delete or replace the GitHub release asset.
4. Rerun `tools/release-mac.sh --validate-only` before publishing a fixed feed.

Deferred:

- Delta updates after at least two full Sparkle archives exist.
- Sparkle key-rotation drill after this first updater-backed release ships.
