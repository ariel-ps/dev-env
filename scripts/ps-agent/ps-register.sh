#!/usr/bin/env bash
# ps-register — register a user in ps-platform without touching the UI.
#
# Replicates what the browser does:
#   1. Login via Frontegg (email/password) → JWT
#   2. GET /api/access/register-login with that JWT → creates user+tenant in DB
#
# Usage:
#   ps-register <email> <password> [domain]
#
# domain defaults to ariel-ps.dev.prompt.security
#
# Examples:
#   ps-register user@company.com mypassword
#   ps-register user@company.com mypassword other-env.dev.prompt.security

ps-register() {
  local FRONTEGG_BASE_URL="https://dev-auth.prompt.security"

  local email="${1:-}"
  local password="${2:-}"
  local domain="${3:-ariel-ps.dev.prompt.security}"

  if [[ -z "$email" || -z "$password" ]]; then
    echo "usage: ps-register <email> <password> [domain]" >&2
    return 1
  fi

  echo "→ Logging in to Frontegg as $email ..."
  local response
  response=$(curl -fsS -X POST "$FRONTEGG_BASE_URL/identity/resources/auth/v1/user" \
    -H "content-type: application/json" \
    -H "frontegg-vendor-host: $FRONTEGG_BASE_URL" \
    -d "{\"email\": \"$email\", \"password\": \"$password\"}")

  local token
  token=$(printf '%s' "$response" | jq -r '.accessToken // .access_token // empty')

  if [[ -z "$token" ]]; then
    echo "✗ Frontegg login failed. Response:" >&2
    printf '%s\n' "$response" | jq . >&2
    return 1
  fi

  echo "✓ Got JWT (${token:0:20}...)"

  echo "→ Calling register-login on $domain ..."
  local status
  status=$(curl -fsS -o /dev/null -w "%{http_code}" \
    "https://$domain/api/access/register-login" \
    -H "authorization: Bearer $token")

  if [[ "$status" == "200" ]]; then
    echo "✓ Registered successfully ($status)"
  else
    echo "✗ register-login returned HTTP $status" >&2
    return 1
  fi
}
