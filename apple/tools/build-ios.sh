#!/usr/bin/env bash
# Build or test the iOS + Watch bundle on Xcode 27 / iOS 27 simulators.
#
# swift-markdown's cmark-gfm dependency still targets watchOS 8.0, which
# Xcode 27 rejects. Point Xcode at Config/Shared.xcconfig so the override
# applies to SPM packages as well as app targets.
#
# Usage:
#   ./tools/build-ios.sh build
#   ./tools/build-ios.sh test -only-testing:ClawdmeteriOSTests
#   IOS_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0' ./tools/build-ios.sh build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export XCODE_XCCONFIG_FILE="${ROOT}/Config/Shared.xcconfig"

cd "$ROOT"
if [[ ! -f Clawdmeter.xcodeproj/project.pbxproj ]]; then
  xcodegen
fi

DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=27.0}"
DERIVED="${DERIVED_DATA_PATH:-/tmp/ClawdmeterDerived}"

ACTION="${1:-build}"
shift || true

exec xcodebuild \
  -scheme "Clawdmeter (iOS)" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -xcconfig Config/Shared.xcconfig \
  "$ACTION" \
  "$@"
