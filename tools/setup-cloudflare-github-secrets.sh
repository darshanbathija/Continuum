#!/usr/bin/env bash
# Configure GitHub Actions secrets for Cloudflare Worker deploys from local CLI auth.
#
# Reads Wrangler OAuth credentials (wrangler login / wrangler auth token) and stores:
#   - CLOUDFLARE_API_TOKEN          (current access token)
#   - CLOUDFLARE_OAUTH_REFRESH_TOKEN (long-lived; CI refreshes before deploy)
#   - CLOUDFLARE_ACCOUNT_ID
#
# Usage:
#   ./tools/setup-cloudflare-github-secrets.sh
#   CLOUDFLARE_API_TOKEN=... ./tools/setup-cloudflare-github-secrets.sh   # manual override
#
# Requires: gh (authenticated), wrangler login on this machine.

set -euo pipefail

REPO="${GITHUB_REPO:-darshanbathija/Continuum}"
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELAY_DIR="$ROOT/infra/relay"
WRANGLER_VERSION="${WRANGLER_VERSION:-3.114.17}"
WRANGLER_AUTH_VERSION="${WRANGLER_AUTH_VERSION:-4.100.0}"
WRANGLER_CONFIG="${HOME}/Library/Preferences/.wrangler/config/default.toml"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required. Install from https://cli.github.com/" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

read_wrangler_refresh_token() {
  if [[ ! -f "$WRANGLER_CONFIG" ]]; then
    return 1
  fi
  grep '^refresh_token' "$WRANGLER_CONFIG" | cut -d'"' -f2
}

read_wrangler_oauth_token() {
  if command -v bunx >/dev/null 2>&1; then
    local from_cli
    from_cli="$(
      cd "$RELAY_DIR" && bunx "wrangler@${WRANGLER_AUTH_VERSION}" auth token --json 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token",""))' || true
    )"
    if [[ -n "$from_cli" ]]; then
      printf '%s' "$from_cli"
      return 0
    fi
  fi
  if [[ -f "$WRANGLER_CONFIG" ]]; then
    grep '^oauth_token' "$WRANGLER_CONFIG" | cut -d'"' -f2
    return 0
  fi
  return 1
}

read_wrangler_account_id() {
  if [[ -n "$ACCOUNT_ID" ]]; then
    printf '%s' "$ACCOUNT_ID"
    return 0
  fi
  local whoami
  whoami="$(
    cd "$RELAY_DIR" && bunx "wrangler@${WRANGLER_AUTH_VERSION}" whoami 2>/dev/null \
      | awk -F'|' '/Account ID/ {getline; gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}'
  )"
  if [[ -n "$whoami" ]]; then
    printf '%s' "$whoami"
    return 0
  fi
  # wrangler.toml account_id fallback
  awk -F'"' '/^account_id/ {print $2; exit}' "$RELAY_DIR/wrangler.toml"
}

resolve_credentials() {
  local access refresh account

  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    access="$CLOUDFLARE_API_TOKEN"
    refresh="${CLOUDFLARE_OAUTH_REFRESH_TOKEN:-}"
  else
    access="$(read_wrangler_oauth_token)" || {
      echo "Could not read Wrangler OAuth token. Run: wrangler login" >&2
      exit 1
    }
    refresh="$(read_wrangler_refresh_token)" || {
      echo "Could not read Wrangler refresh token from ${WRANGLER_CONFIG}." >&2
      exit 1
    }
  fi

  account="$(read_wrangler_account_id)"
  if [[ -z "$account" ]]; then
    echo "Could not resolve Cloudflare account id (wrangler whoami / wrangler.toml)." >&2
    exit 1
  fi

  ACCESS_TOKEN="$access"
  REFRESH_TOKEN="$refresh"
  ACCOUNT_ID="$account"
}

verify_token() {
  local token="$1"
  CLOUDFLARE_API_TOKEN="$token" CLOUDFLARE_ACCOUNT_ID="$ACCOUNT_ID" \
    bunx "wrangler@${WRANGLER_VERSION}" deploy --dry-run --env staging >/dev/null
}

resolve_credentials
echo "Verifying Cloudflare token against relay staging dry-run..."
(cd "$RELAY_DIR" && verify_token "$ACCESS_TOKEN")

echo "Setting GitHub Actions secrets on ${REPO}..."
printf '%s' "$ACCESS_TOKEN" | gh secret set CLOUDFLARE_API_TOKEN --repo "$REPO" --app actions
printf '%s' "$ACCOUNT_ID" | gh secret set CLOUDFLARE_ACCOUNT_ID --repo "$REPO" --app actions
if [[ -n "$REFRESH_TOKEN" ]]; then
  printf '%s' "$REFRESH_TOKEN" | gh secret set CLOUDFLARE_OAUTH_REFRESH_TOKEN --repo "$REPO" --app actions
fi

echo "Configured:"
gh secret list --repo "$REPO" | grep '^CLOUDFLARE_' || gh secret list --repo "$REPO"
echo "Done. CI will refresh OAuth via tools/cloudflare-ci-auth.sh before deploy."
