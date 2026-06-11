#!/usr/bin/env bash
# Open the iOS project in Xcode with watchOS deployment overrides applied.
# Without this, Xcode 27 builds fail on swift-markdown/cmark-gfm watchOS 8.0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export XCODE_XCCONFIG_FILE="${ROOT}/Config/Shared.xcconfig"

cd "$ROOT"
if [[ ! -f Clawdmeter.xcodeproj/project.pbxproj ]]; then
  xcodegen
fi

open Clawdmeter.xcodeproj
