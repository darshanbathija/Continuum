#!/usr/bin/env bash
# Bootstrap continuum-agent on Linux VPS (R1 1B-b).
# Ships a systemd unit template; the headless binary is distributed separately.
set -euo pipefail

INSTALL_DIR="${CONTINUUM_AGENT_DIR:-/opt/clawdmeter}"
UNIT_NAME="continuum-agent.service"
USER_NAME="${CONTINUUM_AGENT_USER:-$USER}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root or with sudo." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
if [[ -f "$(dirname "$0")/continuum-agent.sh" ]]; then
  install -m 755 "$(dirname "$0")/continuum-agent.sh" "${INSTALL_DIR}/continuum-agent"
else
  install -m 755 "$(dirname "$0")/continuum-agent.stub.sh" "${INSTALL_DIR}/continuum-agent"
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${UNIT_NAME}"
systemctl restart "${UNIT_NAME}"

echo "continuum-agent installed. Pair from Mac/iPhone Settings → Devices after relay pairing."
