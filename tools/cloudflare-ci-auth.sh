#!/usr/bin/env bash
# Resolve CLOUDFLARE_API_TOKEN for CI from either:
#   1. A static Account API token (CLOUDFLARE_API_TOKEN), or
#   2. A Wrangler OAuth refresh token (CLOUDFLARE_OAUTH_REFRESH_TOKEN).
#
# When a refresh token is present, exchanges it for a short-lived access token
# using Wrangler's public OAuth client id (PKCE, no client secret).
# Exports CLOUDFLARE_API_TOKEN for subsequent steps; appends to GITHUB_ENV in Actions.

set -euo pipefail

WRANGLER_CLIENT_ID="${WRANGLER_CLIENT_ID:-54d11594-84e4-41aa-b438-e81b8fa78ee7}"
TOKEN_URL="${WRANGLER_TOKEN_URL:-https://dash.cloudflare.com/oauth2/token}"

refresh_access_token() {
  local refresh_token="$1"
  local response access_token
  response="$(
    curl -fsS -X POST "$TOKEN_URL" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data "grant_type=refresh_token&refresh_token=${refresh_token}&client_id=${WRANGLER_CLIENT_ID}"
  )"
  access_token="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' <<<"$response")"
  if [[ -z "$access_token" ]]; then
    echo "Cloudflare OAuth refresh returned an empty access token." >&2
    exit 1
  fi
  printf '%s' "$access_token"
}

if [[ -n "${CLOUDFLARE_OAUTH_REFRESH_TOKEN:-}" ]]; then
  export CLOUDFLARE_API_TOKEN
  CLOUDFLARE_API_TOKEN="$(refresh_access_token "$CLOUDFLARE_OAUTH_REFRESH_TOKEN")"
  export CLOUDFLARE_API_TOKEN
fi

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "CLOUDFLARE_API_TOKEN is not set and CLOUDFLARE_OAUTH_REFRESH_TOKEN is unavailable." >&2
  echo "Run tools/setup-cloudflare-github-secrets.sh on a machine with wrangler login." >&2
  exit 1
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}" >> "$GITHUB_ENV"
fi
