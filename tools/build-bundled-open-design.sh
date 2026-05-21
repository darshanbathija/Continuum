#!/usr/bin/env bash
# Build Open Design and stage it under apple/ClawdmeterMac/Resources/Vendor/open-design/
# so the Mac app bundles it. OpenDesignDaemonManager.locateOpenDesignEntry() reads from
# this path at runtime.
#
# Bundles four things:
#   1. apps/daemon/dist/                    — compiled daemon (cli.js + sidecar)
#   2. apps/web/out/                        — Next.js static export of the editor UI
#   3. apps/daemon/node_modules/            — production-deduped, arm64 prebuilds
#   4. plugins/_official/clawdmeter-bridge/ — mirrored from tools/clawdmeter-open-design-plugin/
#   5. bridge-host/                         — mirrored from tools/clawdmeter-bridge-host/
#
# Per-file codesign of *.node native modules + bundle-sign of the Vendor/open-design/
# tree. `codesign --deep` is discouraged by Apple; sign nested Mach-O explicitly.
#
# Skip via CLAWDMETER_SKIP_BUNDLED_OPEN_DESIGN=1 (dev iteration). Source repo location
# is controlled by OPEN_DESIGN_SRC; defaults to "$HOME/Downloads/Open Design/open-design"
# matching the user's existing checkout.
#
# Pinned to Open Design 0.7.0 (the v2/v2.1 plan was reviewed against this version).
# Bump PINNED_VERSION + re-run the plan's verification checklist before bumping further.

set -euo pipefail

PINNED_VERSION="0.7.0"
OPEN_DESIGN_SRC="${OPEN_DESIGN_SRC:-$HOME/Downloads/Open Design/open-design}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/apple/ClawdmeterMac/Resources/Vendor/open-design"
PLUGIN_SRC="$REPO_ROOT/tools/clawdmeter-open-design-plugin"
BRIDGE_SRC="$REPO_ROOT/tools/clawdmeter-bridge-host"

if [[ "${CLAWDMETER_SKIP_BUNDLED_OPEN_DESIGN:-0}" == "1" ]]; then
  echo "Skipping bundled Open Design (CLAWDMETER_SKIP_BUNDLED_OPEN_DESIGN=1)"
  exit 0
fi

echo "→ Bundled Open Design target: $VENDOR_DIR (pinned $PINNED_VERSION)"

# ────────────────────────────────────────────────────────────────────────
# Preflight
# ────────────────────────────────────────────────────────────────────────

if [[ ! -d "$OPEN_DESIGN_SRC" ]]; then
  echo "✗ OPEN_DESIGN_SRC not found: $OPEN_DESIGN_SRC" >&2
  echo "  Clone https://github.com/darshanbathija/open-design and set OPEN_DESIGN_SRC." >&2
  exit 1
fi

ACTUAL_VERSION="$(node -p "require('$OPEN_DESIGN_SRC/package.json').version" 2>/dev/null || echo unknown)"
if [[ "$ACTUAL_VERSION" != "$PINNED_VERSION" ]]; then
  echo "⚠ OPEN_DESIGN_SRC is version $ACTUAL_VERSION; plan was reviewed against $PINNED_VERSION." >&2
  echo "  Set CLAWDMETER_OD_VERSION_OVERRIDE=1 to proceed anyway." >&2
  [[ "${CLAWDMETER_OD_VERSION_OVERRIDE:-0}" != "1" ]] && exit 1
fi

command -v pnpm >/dev/null 2>&1 || { echo "✗ pnpm not installed (npm i -g pnpm)" >&2; exit 1; }

# Fast path: if pinned version + plugin sources haven't changed, skip rebuild.
# Stamp uses tar-of-listing | shasum so paths with spaces don't break xargs.
STAMP="$VENDOR_DIR/.clawdmeter-stamp"
hash_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then echo "0"; return; fi
  ( cd "$dir" && find . -type f -print0 | sort -z | tar --null --no-recursion -cf - --files-from=- 2>/dev/null | shasum | cut -d' ' -f1 ) || echo "0"
}
EXPECTED_STAMP="od=$PINNED_VERSION plugin=$(hash_dir "$PLUGIN_SRC") bridge=$(hash_dir "$BRIDGE_SRC")"
if [[ -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$EXPECTED_STAMP" ]]; then
  echo "✓ Bundle already up-to-date (stamp matches). Delete $STAMP to force rebuild."
  exit 0
fi
echo "▸ Stamp: $EXPECTED_STAMP"

# ────────────────────────────────────────────────────────────────────────
# 1. Build Open Design (pnpm install + per-package build)
# ────────────────────────────────────────────────────────────────────────

echo "▸ pnpm install (arm64 prebuilds for better-sqlite3)…"
(
  cd "$OPEN_DESIGN_SRC"
  # --config.platform=darwin + --config.arch=arm64 forces arm64 native prebuilds
  # so DMG works on Apple Silicon. Universal build is a separate concern.
  pnpm install --frozen-lockfile --config.platform=darwin --config.arch=arm64 2>&1 | tail -20
)

echo "▸ pnpm build daemon + web (static export)…"
(
  cd "$OPEN_DESIGN_SRC"
  pnpm -F @open-design/daemon build 2>&1 | tail -10
  # Web is built with the default next.config.ts which detects production + no
  # OD_WEB_OUTPUT_MODE → static export to apps/web/out/.
  pnpm -F @open-design/web build 2>&1 | tail -10
)

if [[ ! -f "$OPEN_DESIGN_SRC/apps/daemon/dist/cli.js" ]]; then
  echo "✗ Daemon build produced no apps/daemon/dist/cli.js" >&2; exit 1
fi
if [[ ! -f "$OPEN_DESIGN_SRC/apps/web/out/index.html" ]]; then
  echo "✗ Web build produced no apps/web/out/index.html (verify static export mode)" >&2; exit 1
fi

# ────────────────────────────────────────────────────────────────────────
# 2. Stage into Vendor/open-design/
# ────────────────────────────────────────────────────────────────────────

echo "▸ Staging Vendor/open-design/…"
rm -rf "$VENDOR_DIR"
mkdir -p "$VENDOR_DIR/apps/daemon" "$VENDOR_DIR/apps/web" "$VENDOR_DIR/plugins/_official" "$VENDOR_DIR/bridge-host"

# Daemon dist
rsync -a --delete "$OPEN_DESIGN_SRC/apps/daemon/dist/" "$VENDOR_DIR/apps/daemon/dist/"
cp "$OPEN_DESIGN_SRC/apps/daemon/package.json" "$VENDOR_DIR/apps/daemon/package.json"

# Web static export
rsync -a --delete "$OPEN_DESIGN_SRC/apps/web/out/" "$VENDOR_DIR/apps/web/out/"

# Production node_modules (deduped via pnpm deploy into a temp dir, then rsync)
TMP_DEPLOY="$(mktemp -d -t clawdmeter-od-deploy-XXXXXX)"
trap 'rm -rf "$TMP_DEPLOY"' EXIT
(
  cd "$OPEN_DESIGN_SRC"
  # --legacy: pnpm v10+ requires either inject-workspace-packages=true or
  # --legacy for `deploy`. Open Design's workspace doesn't set the former
  # so we use the latter to ship a self-contained node_modules tree.
  pnpm --filter @open-design/daemon deploy --prod --legacy "$TMP_DEPLOY/daemon" 2>&1 | tail -10
)
if [[ -d "$TMP_DEPLOY/daemon/node_modules" ]]; then
  rsync -a "$TMP_DEPLOY/daemon/node_modules/" "$VENDOR_DIR/apps/daemon/node_modules/"
else
  echo "✗ pnpm deploy produced no node_modules under $TMP_DEPLOY/daemon" >&2; exit 1
fi

# Plugin source mirror (read-only inside .app)
if [[ -d "$PLUGIN_SRC" ]]; then
  rsync -a --delete "$PLUGIN_SRC/" "$VENDOR_DIR/plugins/_official/clawdmeter-bridge/"
else
  echo "⚠ Plugin source missing at $PLUGIN_SRC — handoff button won't render in Design canvas" >&2
fi

# Bridge sidecar host mirror
if [[ -d "$BRIDGE_SRC" ]]; then
  rsync -a --delete "$BRIDGE_SRC/" "$VENDOR_DIR/bridge-host/"
else
  echo "⚠ Bridge host source missing at $BRIDGE_SRC — Code→Design handoff won't mint import tokens" >&2
fi

# ────────────────────────────────────────────────────────────────────────
# 3. Sign nested Mach-O and the bundle (per-file, not --deep)
# ────────────────────────────────────────────────────────────────────────

# DEVELOPMENT_TEAM is read from project.yml; fall back to detection.
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(awk -F'"' '/DEVELOPMENT_TEAM/{print $2; exit}' "$REPO_ROOT/apple/project.yml" 2>/dev/null || true)}"
if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  echo "⚠ DEVELOPMENT_TEAM not set — skipping codesign. Set DEVELOPMENT_TEAM env or in project.yml." >&2
else
  echo "▸ Per-file codesign of native .node binaries + bundle sign (team $DEVELOPMENT_TEAM)…"
  NODE_COUNT="$(find "$VENDOR_DIR" -name '*.node' -type f | wc -l | tr -d ' ')"
  if [[ "$NODE_COUNT" -gt 0 ]]; then
    find "$VENDOR_DIR" -name '*.node' -type f -print0 | \
      xargs -0 -n1 codesign --force --options runtime --timestamp \
        --sign "$DEVELOPMENT_TEAM" 2>&1 | grep -E "error|warning" || true
    echo "✓ Signed $NODE_COUNT .node binaries"
  fi
  # Bundle-sign the whole tree (not --deep — top-level only since inner
  # Mach-O was already signed above).
  codesign --force --options runtime --timestamp --sign "$DEVELOPMENT_TEAM" "$VENDOR_DIR" || true
  codesign --verify --strict "$VENDOR_DIR" && echo "✓ Vendor/open-design/ signature verified"
fi

# ────────────────────────────────────────────────────────────────────────
# 4. Stamp + size report
# ────────────────────────────────────────────────────────────────────────

echo "$EXPECTED_STAMP" > "$STAMP"

SIZE="$(du -sh "$VENDOR_DIR" | awk '{print $1}')"
echo ""
echo "✅ Bundled Open Design ready: $VENDOR_DIR ($SIZE)"
echo "   Re-run after Open Design version bump or plugin source changes."
