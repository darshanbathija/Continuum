fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### build_mac_dmg

```sh
[bundle exec] fastlane build_mac_dmg
```

Package the Mac app into a DMG. Uses tools/build-mac-dmg.sh which
already drives xcodegen + xcodebuild archive + hdiutil. Output:
`dist/Continuum-<version>-arm64.dmg`.

### release

```sh
[bundle exec] fastlane release
```

Full release: bump build number, archive Mac + iOS, ship TestFlight,
draft a GitHub release with the DMG attached.

### asc_verify

```sh
[bundle exec] fastlane asc_verify
```

Read-only: verify the ASC API key auths + list existing apps.

### probe_prefix

```sh
[bundle exec] fastlane probe_prefix
```

Probe whether a bundle-id prefix is available (creates PROBE_ID).

### continuum_bootstrap_ids

```sh
[bundle exec] fastlane continuum_bootstrap_ids
```

Pre-create the 6 App IDs via the App Store Connect API (the API key path
that works headlessly — fastlane's own App-ID creation needs a portal login).
Best-effort capabilities so the app-store profiles carry the entitlements.

### continuum_match

```sh
[bundle exec] fastlane continuum_match
```

Sync App Store distribution cert + profiles for all bundle IDs (API key
auth via match; app-store profiles need no devices).

### asc_check_devportal

```sh
[bundle exec] fastlane asc_check_devportal
```

Read-only: confirm the API key can reach Certificates/IDs/Profiles.

### continuum_produce

```sh
[bundle exec] fastlane continuum_produce
```

Create the iOS App Store Connect app record (ASC API key — no dev-center
login). Requires the App ID to already exist (created by the archive's
-allowProvisioningUpdates). Idempotent.

### continuum_archive

```sh
[bundle exec] fastlane continuum_archive
```

Archive iOS + Watch only (Xcode-managed automatic signing + API key).

### continuum_ios_testflight

```sh
[bundle exec] fastlane continuum_ios_testflight
```

Full iOS TestFlight: archive (auto-provision) → app record → upload.

----


## iOS

### ios match_dev

```sh
[bundle exec] fastlane ios match_dev
```

Sync development certs + profiles for all 5 targets.

### ios match_release

```sh
[bundle exec] fastlane ios match_release
```

Sync App Store certs + profiles. Run before `release`.

### ios ios_testflight

```sh
[bundle exec] fastlane ios ios_testflight
```

Archive the iOS app + Watch extension and upload to TestFlight.
The Watch app rides along in the same .xcarchive since it's embedded
in the iOS bundle.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
