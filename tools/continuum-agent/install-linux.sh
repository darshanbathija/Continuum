#!/usr/bin/env bash
# Bootstrap continuum-agent on Linux VPS / EC2 (R1 1B-b).
set -euo pipefail

INSTALL_DIR="${CONTINUUM_AGENT_DIR:-/opt/clawdmeter}"
UNIT_NAME="continuum-agent.service"
USER_NAME="${CONTINUUM_AGENT_USER:-${SUDO_USER:-root}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# SECURITY TODO: before production use, pin CONTINUUM_AGENT_REF to a reviewed
# commit SHA (not a moving branch) and confirm the GitHub org below is owned by
# us. A `main` pin lets whoever controls the repo/org ship arbitrary code to
# every box that runs this installer. Overridable via the env var for testing.
CONTINUUM_AGENT_REF="${CONTINUUM_AGENT_REF:-main}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi

# Refuse to install the daemon to run as root — it spawns untrusted agent
# processes, so it must run under a dedicated unprivileged user.
if [[ "$USER_NAME" == "root" ]]; then
  echo "error: refusing to install continuum-agent as root." >&2
  echo "Create a dedicated unprivileged user and re-run with CONTINUUM_AGENT_USER=<user>." >&2
  exit 1
fi

detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo "arm64" ;;
    x86_64|amd64) echo "amd64" ;;
    *) echo "unsupported" ;;
  esac
}

require_go_123() {
  local version major minor rest
  version="$(go env GOVERSION 2>/dev/null || go version | awk '{print $3}')"
  version="${version#go}"
  major="${version%%.*}"
  rest="${version#*.}"
  minor="${rest%%.*}"
  if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
    if (( major > 1 || (major == 1 && minor >= 23) )); then
      return 0
    fi
  fi
  echo "error: Go 1.23+ is required to build continuum-agent from source; found go${version}." >&2
  echo "Set CONTINUUM_AGENT_BINARY_URL to a prebuilt binary or install a newer Go toolchain." >&2
  return 1
}

install_binary() {
  local arch
  arch="$(detect_arch)"
  if [[ "$arch" == "unsupported" ]]; then
    echo "error: unsupported architecture $(uname -m)" >&2
    return 1
  fi

  mkdir -p "$INSTALL_DIR/data"

  if [[ -n "${CONTINUUM_AGENT_BINARY_URL:-}" ]]; then
    echo "Downloading continuum-agent from CONTINUUM_AGENT_BINARY_URL…"
    curl -fsSL "$CONTINUUM_AGENT_BINARY_URL" -o "${INSTALL_DIR}/continuum-agent"
    chmod +x "${INSTALL_DIR}/continuum-agent"
    return 0
  fi

  local bundled="${SCRIPT_DIR}/dist/continuum-agent-linux-${arch}"
  if [[ -f "$bundled" ]]; then
    install -m 755 "$bundled" "${INSTALL_DIR}/continuum-agent"
    return 0
  fi

  if [[ -f "${SCRIPT_DIR}/linux/main.go" ]] && command -v go >/dev/null 2>&1; then
    require_go_123
    echo "Building continuum-agent from source…"
    (
      cd "${SCRIPT_DIR}/linux"
      CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
        go build -trimpath -ldflags="-s -w" -o "${INSTALL_DIR}/continuum-agent" .
    )
    chmod +x "${INSTALL_DIR}/continuum-agent"
    return 0
  fi

  if command -v go >/dev/null 2>&1; then
    require_go_123
    echo "Building continuum-agent from upstream source (piped install)…"
    local tmp
    tmp="$(mktemp -d)"
    local base="${CONTINUUM_AGENT_SOURCE_BASE:-https://raw.githubusercontent.com/clawdmeter/clawdmeter/${CONTINUUM_AGENT_REF}/tools/continuum-agent/linux}"
    local files=(main.go sessions.go spawn.go relay_client.go relay_pair.go go.mod go.sum)
    local file
    for file in "${files[@]}"; do
      curl -fsSL "${base}/${file}" -o "${tmp}/${file}"
    done
    (
      cd "$tmp"
      CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
        go build -trimpath -ldflags="-s -w" -o "${INSTALL_DIR}/continuum-agent" .
    )
    rm -rf "$tmp"
    chmod +x "${INSTALL_DIR}/continuum-agent"
    return 0
  fi

  echo "error: no continuum-agent binary available." >&2
  echo "Set CONTINUUM_AGENT_BINARY_URL, run tools/continuum-agent/build-linux.sh, or install Go to compile on-box." >&2
  return 1
}

install_binary

# Load host metadata written by AWS cloud-init (optional).
if [[ -f /etc/clawdmeter/env ]]; then
  set -a
  # shellcheck disable=SC1091
  source /etc/clawdmeter/env
  set +a
fi

cat > "/etc/systemd/system/${UNIT_NAME}" <<EOF
[Unit]
Description=Clawdmeter continuum-agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/continuum-agent serve
Restart=always
RestartSec=5
Environment=CLAWDMETER_DATA_DIR=${INSTALL_DIR}/data
# Default to localhost/tailnet bind. Set CLAWDMETER_BIND_ALL=1 in
# /etc/clawdmeter/env only if the box is behind a trusted network boundary.
EnvironmentFile=-/etc/clawdmeter/env
# Hardening: drop privilege-escalation and confine the writable surface.
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=${INSTALL_DIR}

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${UNIT_NAME}"
systemctl restart "${UNIT_NAME}"

echo "continuum-agent installed."
echo "Check: systemctl status ${UNIT_NAME}"
echo "Pair from Mac/iPhone: Settings → Devices → Add execution host (relay)."
