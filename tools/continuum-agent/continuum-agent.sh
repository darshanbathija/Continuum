#!/usr/bin/env bash
# continuum-agent — headless Clawdmeter daemon wrapper (R1 1B).
set -euo pipefail

CMD="${1:-serve}"
shift || true

APP_NAME="${CLAWDMETER_APP_NAME:-Clawdmeter}"
APP_PATH="${CLAWDMETER_APP_PATH:-/Applications/${APP_NAME}.app}"
HTTP_PORT="${CLAWDMETER_HTTP_PORT:-21731}"
LOG_DIR="${HOME}/Library/Logs/Clawdmeter"
TOKEN_FILE="${HOME}/.clawdmeter/agent-token"

mkdir -p "$(dirname "$TOKEN_FILE")" "$LOG_DIR"

case "$CMD" in
  serve)
    if [[ -d "$APP_PATH" ]]; then
      exec /usr/bin/open -a "$APP_PATH" --args --headless-agent
    fi
    echo "error: ${APP_PATH} not found. Install Clawdmeter or set CLAWDMETER_APP_PATH." >&2
    exit 1
    ;;
  pair)
    HOST="${CLAWDMETER_PAIR_HOST:-$(hostname -f 2>/dev/null || hostname)}"
    PORT="${CLAWDMETER_HTTP_PORT:-21731}"
    WS_PORT="${CLAWDMETER_WS_PORT:-$((PORT + 1))}"
    if [[ -f "$TOKEN_FILE" ]]; then
      TOKEN="$(cat "$TOKEN_FILE")"
    else
      TOKEN="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
      echo "$TOKEN" > "$TOKEN_FILE"
      chmod 600 "$TOKEN_FILE"
    fi
    URL="clawdmeter://${HOST}:${PORT}?token=${TOKEN}&ws=${WS_PORT}"
    echo "$URL"
    echo ""
    echo "Scan this URL with Clawdmeter on iPhone or Mac."
    if command -v qrencode >/dev/null 2>&1; then
      qrencode -t ANSIUTF8 "$URL"
    fi
    ;;
  show-token)
    if [[ -f "$TOKEN_FILE" ]]; then
      cat "$TOKEN_FILE"
    else
      echo "error: no token at ${TOKEN_FILE}. Run: continuum-agent pair" >&2
      exit 1
    fi
    ;;
  health)
    curl -fsS "http://127.0.0.1:${HTTP_PORT}/health" || exit 1
    echo ""
    ;;
  *)
    echo "usage: continuum-agent {serve|pair|show-token|health}" >&2
    exit 1
    ;;
esac
