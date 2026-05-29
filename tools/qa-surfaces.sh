#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# qa-surfaces.sh — repeatable build → test → launch → log-capture gate for
# Continuum's Mac surfaces. Pairs with docs/qa/surface-checklist.md, which
# lists every surface and its expected behaviour (the manual pass).
#
# USAGE:
#   tools/qa-surfaces.sh                 # build + shared tests + launch + log capture
#   RUN_MAC_TESTS=1 tools/qa-surfaces.sh # also run the Mac XCTest suite (slow)
#   LAUNCH=0 tools/qa-surfaces.sh        # CI-style: build + tests only, no GUI
#   CAPTURE_SECS=60 tools/qa-surfaces.sh # capture a longer runtime-log window
#
# Every run writes artifacts (build log, test logs, runtime logs) to
# tools/qa-logs/qa-<timestamp>/ so results are diffable across runs.
# ---------------------------------------------------------------------------
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO_ROOT"
STAMP="$(date +%Y%m%d-%H%M%S)"; OUT="tools/qa-logs/qa-$STAMP"; mkdir -p "$OUT"
SCHEME="Clawdmeter (Mac)"; PROJ="apple/Clawdmeter.xcodeproj"; DD=".build/dd-audit"
RUN_MAC_TESTS="${RUN_MAC_TESTS:-0}"; LAUNCH="${LAUNCH:-1}"; CAPTURE_SECS="${CAPTURE_SECS:-25}"

step(){ printf '\n\033[1m▶ %s\033[0m\n' "$1"; }

step "1/5 regenerate project (xcodegen)"
( cd apple && xcodegen generate >/dev/null ) && echo "  ok"

step "2/5 build (CODE_SIGNING_ALLOWED=NO)"
if xcodebuild build -project "$PROJ" -scheme "$SCHEME" \
     -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
     CODE_SIGNING_ALLOWED=NO > "$OUT/build.log" 2>&1; then
  echo "  BUILD SUCCEEDED ($(grep -c 'warning:' "$OUT/build.log") warnings)"
else
  echo "  BUILD FAILED → $OUT/build.log"; grep -E 'error:' "$OUT/build.log" | head; exit 1
fi

step "3/5 shared unit tests (swift test)"
if ( cd apple/ClawdmeterShared && swift test ) > "$OUT/shared-tests.log" 2>&1; then
  echo "  ok — $(grep -Eo 'Executed [0-9]+ tests' "$OUT/shared-tests.log" | tail -1)"
else
  echo "  FAILED → $OUT/shared-tests.log"; tail -20 "$OUT/shared-tests.log"
fi

if [ "$RUN_MAC_TESTS" = "1" ]; then
  step "3b Mac XCTest suite (xcodebuild test — slow)"
  if xcodebuild test -project "$PROJ" -scheme "$SCHEME" \
       -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
       CODE_SIGNING_ALLOWED=NO > "$OUT/mac-tests.log" 2>&1; then
    echo "  ok — $(grep -Eo 'Executed [0-9]+ tests' "$OUT/mac-tests.log" | tail -1)"
  else
    echo "  FAILED → $OUT/mac-tests.log"; grep -E "error:|failed" "$OUT/mac-tests.log" | head -20
  fi
fi

APP="$(find "$DD/Build/Products" -maxdepth 3 -name 'Continuum.app' 2>/dev/null | head -1)"
if [ "$LAUNCH" = "1" ] && [ -n "$APP" ]; then
  step "4/5 launch + capture ${CAPTURE_SECS}s of runtime logs"
  echo "  $APP"
  open "$APP"
  sleep "$CAPTURE_SECS"
  log show --predicate 'subsystem == "com.clawdmeter.mac"' --last 5m --style syslog \
    > "$OUT/runtime-logs.txt" 2>/dev/null || true
  LINES="$(grep -c . "$OUT/runtime-logs.txt" 2>/dev/null || echo 0)"
  ERRS="$(grep -cE '\[(error|fault)\]|<Error>|<Fault>' "$OUT/runtime-logs.txt" 2>/dev/null || echo 0)"
  echo "  captured $LINES log lines (~$ERRS error/fault) → $OUT/runtime-logs.txt"
else
  step "4/5 launch skipped (LAUNCH=0 or Continuum.app not found)"
fi

step "5/5 manual surface pass"
echo "  Walk docs/qa/surface-checklist.md against the running app."
echo "  Query persisted errors any time:  tools/clawdmeter-logs.sh 7"
echo ""
echo "✓ Artifacts in $OUT/"
