#!/usr/bin/env bash
# Build static Linux continuum-agent binaries (arm64 + amd64).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="${ROOT}/linux"
OUT="${ROOT}/dist"
mkdir -p "$OUT"

if ! command -v go >/dev/null 2>&1; then
  echo "error: Go toolchain not found. Install Go 1.22+ or run inside a golang container." >&2
  exit 1
fi

build_one() {
  local goos=$1
  local goarch=$2
  local out="${OUT}/continuum-agent-linux-${goarch}"
  echo "building ${goos}/${goarch} -> ${out}"
  (
    cd "$SRC"
    CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
      go build -trimpath -ldflags="-s -w" -o "$out" .
  )
  chmod +x "$out"
}

build_one linux arm64
build_one linux amd64

echo "done: ${OUT}/continuum-agent-linux-{arm64,amd64}"
