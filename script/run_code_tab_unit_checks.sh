#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/apple/Clawdmeter.xcodeproj"
SCHEME="Clawdmeter (Mac)"
DESTINATION="platform=macOS"

if [[ -n "${CLAWDMETER_DERIVED_DATA_PATH:-}" ]]; then
  DERIVED_DATA="$CLAWDMETER_DERIVED_DATA_PATH"
  CLEAN_DERIVED_DATA=0
else
  DERIVED_DATA="$(mktemp -d "${TMPDIR:-/tmp}/clawdmeter-code-tab-unit.XXXXXX")"
  CLEAN_DERIVED_DATA=1
fi

cleanup() {
  if [[ "$CLEAN_DERIVED_DATA" == "1" ]]; then
    rm -rf "$DERIVED_DATA"
  fi
}
trap cleanup EXIT

xcodebuild build-for-testing \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA"

TEST_BUNDLE="$(find "$DERIVED_DATA/Build/Products/Debug" -path '*/Continuum.app/Contents/PlugIns/ClawdmeterMacTests.xctest' -type d | head -n 1)"
if [[ -z "$TEST_BUNDLE" ]]; then
  echo "ClawdmeterMacTests.xctest was not produced under $DERIVED_DATA" >&2
  exit 1
fi

TESTS=(
  "ClawdmeterMacTests.SessionLauncherModelTests"
  "ClawdmeterMacTests.WorkspaceTabsTests"
  "ClawdmeterMacTests.WorkbenchStateTests"
  "ClawdmeterMacTests.ChatSendPerProviderTests"
  "ClawdmeterMacTests.AgentControlServerChatRouteTests"
)

for test_class in "${TESTS[@]}"; do
  xcrun xctest -XCTest "$test_class" "$TEST_BUNDLE"
done
