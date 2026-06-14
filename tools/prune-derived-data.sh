#!/usr/bin/env bash
# prune-derived-data.sh — reclaim stale Xcode DerivedData for this project.
#
# Why this exists: every xcodebuild that runs WITHOUT an explicit
# -derivedDataPath uses Xcode's default DerivedData location, which keys a
# `Clawdmeter-<hash>` directory off the .xcodeproj's absolute path. Because we
# build the same project from many conductor worktrees (each a distinct path)
# and re-validate merges from FRESH derived dirs on purpose (see
# clawdmeter-build-validation-gotcha), these dirs pile up — 120 of them, ~120 GB
# in five days, observed 2026-06-14. Nothing reclaims them, so the build/release
# scripts call this at the end of a run to delete the STALE ones.
#
# Safety:
#   - Only ever touches dirs matching Clawdmeter* / ClawdmeterShared* under the
#     default DerivedData root. Never other projects, never ModuleCache.noindex.
#   - Only deletes dirs not modified within $KEEP_HOURS (default 24h), so the
#     dir an active build is using — including the build→shoot handoff in
#     tahoe-verify — is always preserved.
#   - Everything it deletes is a pure build cache that Xcode regenerates.
#   - Never fails its caller: always exits 0.
#
# Usage:
#   tools/prune-derived-data.sh            # prune dirs older than 24h
#   KEEP_HOURS=6 tools/prune-derived-data.sh
#   tools/prune-derived-data.sh --dry-run  # report what would be deleted

set -uo pipefail

KEEP_HOURS="${KEEP_HOURS:-24}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

DD="${HOME}/Library/Developer/Xcode/DerivedData"
[[ -d "$DD" ]] || exit 0

mins=$(( KEEP_HOURS * 60 ))
freed_kb=0
count=0

while IFS= read -r dir; do
  [[ -n "$dir" ]] || continue
  sz=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
  freed_kb=$(( freed_kb + ${sz:-0} ))
  count=$(( count + 1 ))
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '  would remove %6s  %s\n' "$(du -sh "$dir" 2>/dev/null | awk '{print $1}')" "$(basename "$dir")"
  else
    rm -rf "$dir" 2>/dev/null || true
  fi
done < <(find "$DD" -maxdepth 1 -type d \
           \( -name 'Clawdmeter-*' -o -name 'ClawdmeterShared-*' \) \
           -mmin "+${mins}" 2>/dev/null)

freed_h=$(awk -v k="$freed_kb" 'BEGIN{ if (k>=1048576) printf "%.1f GB", k/1048576; else printf "%d MB", k/1024 }')
if [[ "$count" -eq 0 ]]; then
  echo "[prune-derived-data] nothing stale (>${KEEP_HOURS}h) to remove"
elif [[ "$DRY_RUN" == "1" ]]; then
  echo "[prune-derived-data] DRY RUN — ${count} stale dir(s), ~${freed_h} reclaimable"
else
  echo "[prune-derived-data] removed ${count} stale dir(s), freed ~${freed_h}"
fi
exit 0
