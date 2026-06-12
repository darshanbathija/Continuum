#!/usr/bin/env bash
# Bootstrap continuum-agent on Linux VPS / EC2 (R1 1B-b).
set -euo pipefail

INSTALL_DIR="${CONTINUUM_AGENT_DIR:-/opt/clawdmeter}"
UNIT_NAME="continuum-agent.service"
USER_NAME="${CONTINUUM_AGENT_USER:-${SUDO_USER:-root}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi

detect_arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo "arm64" ;;
    x86_64|amd64) echo "amd64" ;;
    *) echo "unsupported" ;;
  esac
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
    echo "Building continuum-agent from upstream source (piped install)…"
    local tmp
    tmp="$(mktemp -d)"
    local base="${CONTINUUM_AGENT_SOURCE_BASE:-https://raw.githubusercontent.com/clawdmeter/clawdmeter/main/tools/continuum-agent/linux}"
    curl -fsSL "${base}/main.go" -o "${tmp}/main.go"
    curl -fsSL "${base}/go.mod" -o "${tmp}/go.mod"
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
Environment=CLAWDMETER_BIND_ALL=1
EnvironmentFile=-/etc/clawdmeter/env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${UNIT_NAME}"
systemctl restart "${UNIT_NAME}"

echo "continuum-agent installed."
echo "Check: systemctl status ${UNIT_NAME}"
echo "Pair from Mac/iPhone: Settings → Devices → Add execution host (relay)."
