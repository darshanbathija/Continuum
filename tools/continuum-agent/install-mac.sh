#!/usr/bin/env bash
# Install Clawdmeter continuum-agent LaunchAgent on macOS (R1 1B-a).
set -euo pipefail

APP_NAME="${CLAWDMETER_APP_NAME:-Clawdmeter}"
APP_PATH="${CLAWDMETER_APP_PATH:-/Applications/${APP_NAME}.app}"
PLIST_ID="com.clawdmeter.agent"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_ID}.plist"
LOG_DIR="${HOME}/Library/Logs/Clawdmeter"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: ${APP_PATH} not found. Set CLAWDMETER_APP_PATH if installed elsewhere." >&2
  exit 1
fi

mkdir -p "$LOG_DIR" "${HOME}/Library/LaunchAgents"

cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_ID}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>${APP_PATH}</string>
    <string>--args</string>
    <string>--headless-agent</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/continuum-agent.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/continuum-agent.err.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
launchctl enable "gui/$(id -u)/${PLIST_ID}"
launchctl kickstart -k "gui/$(id -u)/${PLIST_ID}"

echo "Installed LaunchAgent ${PLIST_ID}."
echo "Logs: ${LOG_DIR}/continuum-agent.log"
