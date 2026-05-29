#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# clawdmeter-logs.sh — query Continuum's (Clawdmeter Mac) persistent logs.
#
# WHY this works with no extra infrastructure: every os.Logger in
# ClawdmeterMac is declared with subsystem "com.clawdmeter.mac" (67 sites,
# verified), and macOS unified logging persists .notice / .error / .fault
# entries to the on-disk log store. So any fresh session can ask "what went
# wrong over the last N days?" via `log show` filtered to that subsystem.
#
# CAVEAT: .debug entries are memory-only and will NOT appear in historical
# `log show` (they only show in a live `--stream`). Genuine errors should be
# logged at .error/.fault to be reviewable here.
#
# USAGE:
#   tools/clawdmeter-logs.sh                      # errors+faults, last 1 day
#   tools/clawdmeter-logs.sh 7                     # errors+faults, last 7 days
#   tools/clawdmeter-logs.sh 3 --all              # every level, last 3 days
#   tools/clawdmeter-logs.sh --stream             # live tail of errors+faults
#   tools/clawdmeter-logs.sh 7 --category Terminal# only the "Terminal" logger category
#
# Output is printed AND saved to tools/qa-logs/logs-<stamp>.txt.
# ---------------------------------------------------------------------------
set -euo pipefail

SUBSYSTEM="com.clawdmeter.mac"
DAYS=1
MODE="errors"      # errors | all
STREAM=0
CATEGORY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --all)      MODE="all" ;;
    --errors)   MODE="errors" ;;
    --stream)   STREAM=1 ;;
    --category) CATEGORY="${2:-}"; shift ;;
    ''|*[!0-9]*) echo "warn: ignoring unrecognized arg '$1'" >&2 ;;
    *)          DAYS="$1" ;;
  esac
  shift
done

PRED="subsystem == \"$SUBSYSTEM\""
[ -n "$CATEGORY" ] && PRED="$PRED AND category == \"$CATEGORY\""
# messageType 16 = error, 17 = fault.
[ "$MODE" = "errors" ] && PRED="$PRED AND (messageType == 16 OR messageType == 17)"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/tools/qa-logs"
mkdir -p "$OUT_DIR"

if [ "$STREAM" -eq 1 ]; then
  echo "▶ streaming live logs for $SUBSYSTEM (mode=$MODE). Ctrl-C to stop."
  exec log stream --predicate "$PRED" --style syslog --level "$([ "$MODE" = all ] && echo debug || echo default)"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_FILE="$OUT_DIR/logs-$STAMP.txt"

echo "▶ Continuum logs — subsystem=$SUBSYSTEM, last ${DAYS}d, mode=$MODE${CATEGORY:+, category=$CATEGORY}"
echo "  predicate: $PRED"
echo "  saving to: $OUT_FILE"
echo "---------------------------------------------------------------------"

SHOW_ARGS=(show --predicate "$PRED" --last "${DAYS}d" --style syslog)
[ "$MODE" = "all" ] && SHOW_ARGS+=(--info --debug)

# Tee to file; `log show` exits non-zero only on bad predicate/permissions.
if ! log "${SHOW_ARGS[@]}" | tee "$OUT_FILE"; then
  echo "error: 'log show' failed — check the predicate or Terminal's Full Disk Access." >&2
  exit 1
fi

COUNT="$(grep -c . "$OUT_FILE" 2>/dev/null || echo 0)"
echo "---------------------------------------------------------------------"
echo "✓ $COUNT line(s). Re-run with a larger day count or --all for more detail."
