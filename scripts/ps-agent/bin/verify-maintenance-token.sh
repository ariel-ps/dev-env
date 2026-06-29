#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  verify-maintenance-token.sh <token>
  echo "<token>" | verify-maintenance-token.sh -

Decodes a Prompt Security maintenance token locally, then verifies it against
the platform using the same agent credentials as pa-api:

  1. PROMPT_API_DOMAIN + PROMPT_API_KEY
  2. /Library/Managed Preferences/com.prompt.security.agent.plist
  3. /Library/Application Support/Prompt/config.toml

Exit codes:
  0  token is valid
  1  token was checked and is invalid
  2  request/configuration error
EOF
}

mask_secret() {
  local value="$1"
  if [[ ${#value} -le 10 ]]; then
    printf '%s\n' '<redacted>'
  else
    printf '%s...%s\n' "${value:0:6}" "${value: -4}"
  fi
}

json_escape() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

toml_app_value() {
  local key="$1"
  awk -F'=' -v wanted="$key" '
    /^[[:space:]]*\[/{section=$0; next}
    section ~ /^[[:space:]]*\[app\][[:space:]]*$/ && $1 ~ "^[[:space:]]*" wanted "[[:space:]]*$" {
      value=$0
      sub(/^[^=]*=/, "", value)
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^'\''|'\''$/, "", value)
      print value
      exit
    }'
}

load_agent_config() {
  local plist="/Library/Managed Preferences/com.prompt.security.agent.plist"
  local cfg="${PROMPT_AGENT_CONFIG:-/Library/Application Support/Prompt/config.toml}"

  PA_API_DOMAIN="${PROMPT_API_DOMAIN:-}"
  PA_API_KEY="${PROMPT_API_KEY:-}"
  PA_API_SOURCE=""
  [[ -n "$PA_API_DOMAIN" || -n "$PA_API_KEY" ]] && PA_API_SOURCE="env"

  if [[ -z "$PA_API_DOMAIN" || -z "$PA_API_KEY" ]]; then
    if [[ -r "$plist" ]]; then
      local plist_domain plist_key
      plist_domain="$(/usr/libexec/PlistBuddy -c 'Print :domain' "$plist" 2>/dev/null || true)"
      plist_key="$(/usr/libexec/PlistBuddy -c 'Print :apiKey' "$plist" 2>/dev/null || true)"

      [[ -z "$PA_API_DOMAIN" && -n "$plist_domain" ]] && PA_API_DOMAIN="$plist_domain"
      [[ -z "$PA_API_KEY" && -n "$plist_key" ]] && PA_API_KEY="$plist_key"
      [[ -n "$PA_API_DOMAIN" && -n "$PA_API_KEY" ]] && PA_API_SOURCE="mdm-plist"
    fi
  fi

  if [[ -z "$PA_API_DOMAIN" || -z "$PA_API_KEY" ]]; then
    local content=""
    if [[ -r "$cfg" ]]; then
      content="$(cat "$cfg" 2>/dev/null || true)"
    else
      content="$(sudo cat "$cfg" 2>/dev/null || true)"
    fi

    if [[ -n "$content" ]]; then
      local cfg_domain cfg_key
      cfg_domain="$(printf '%s\n' "$content" | toml_app_value domain)"
      cfg_key="$(printf '%s\n' "$content" | toml_app_value api_key)"

      [[ -z "$PA_API_DOMAIN" && -n "$cfg_domain" ]] && PA_API_DOMAIN="$cfg_domain"
      [[ -z "$PA_API_KEY" && -n "$cfg_key" ]] && PA_API_KEY="$cfg_key"
      [[ -n "$PA_API_DOMAIN" && -n "$PA_API_KEY" && -z "$PA_API_SOURCE" ]] && PA_API_SOURCE="config.toml"
    fi
  fi

  [[ -n "$PA_API_DOMAIN" && -n "$PA_API_KEY" ]]
}

base64url_decode() {
  local value="$1"
  local remainder

  if [[ ! "$value" =~ ^[A-Za-z0-9_-]+$ ]]; then
    return 1
  fi

  value="$(printf '%s' "$value" | tr '_-' '/+')"
  remainder=$((${#value} % 4))

  case "$remainder" in
    0) ;;
    2) value="${value}==" ;;
    3) value="${value}=" ;;
    *) return 1 ;;
  esac

  if printf '%s' "$value" | base64 --decode 2>/dev/null; then
    return 0
  fi

  printf '%s' "$value" | base64 -D 2>/dev/null
}

print_decoded_token() {
  local decoded

  echo "Decoded token (not proof of validity):"

  if ! decoded="$(base64url_decode "$TOKEN")"; then
    echo "<unable to base64url-decode token>"
    echo
    return
  fi

  if command -v jq >/dev/null 2>&1 && jq . <<<"$decoded" >/dev/null 2>&1; then
    jq . <<<"$decoded"
  else
    echo "$decoded"
  fi

  echo
}

TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -)
      TOKEN="$(cat)"
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$TOKEN" ]]; then
        echo "Only one token may be provided" >&2
        usage >&2
        exit 2
      fi
      TOKEN="$1"
      shift
      ;;
  esac
done

if [[ -z "$TOKEN" ]]; then
  echo "Token is required" >&2
  usage >&2
  exit 2
fi

print_decoded_token

if ! load_agent_config; then
  echo "Failed to resolve PS Agent domain/api_key. Run 'pa-api whoami' to debug credentials." >&2
  exit 2
fi

BASE_URL="$PA_API_DOMAIN"
if [[ "$BASE_URL" != *"://"* ]]; then
  BASE_URL="https://${BASE_URL}"
fi
BASE_URL="${BASE_URL%/}"
ENDPOINT="${BASE_URL}/api/agent/maintenance/v1/verify"
REQUEST_BODY="$(printf '{"token":"%s"}' "$(json_escape "$TOKEN")")"

printf 'domain : %s\n' "$PA_API_DOMAIN"
printf 'app-id : %s\n' "$(mask_secret "$PA_API_KEY")"
printf 'source : %s\n' "${PA_API_SOURCE:-unknown}"

if ! response="$(
  curl --silent --show-error --location \
    --request POST \
    --header "content-type: application/json" \
    --header "app-id: ${PA_API_KEY}" \
    --data "$REQUEST_BODY" \
    --write-out $'\n%{http_code}' \
    "$ENDPOINT"
)"; then
  echo "Request failed" >&2
  exit 2
fi

http_status="${response##*$'\n'}"
body="${response%$'\n'*}"

echo "HTTP ${http_status}"

if command -v jq >/dev/null 2>&1; then
  valid="$(jq -r '.valid // empty' <<<"$body" 2>/dev/null || true)"
  reason="$(jq -r '.reason // empty' <<<"$body" 2>/dev/null || true)"
  message="$(jq -r '.message // empty' <<<"$body" 2>/dev/null || true)"

  if [[ "$valid" == "true" ]]; then
    echo "valid=true"
    exit 0
  fi

  echo "valid=false"
  [[ -n "$reason" ]] && echo "reason=${reason}"
  [[ -n "$message" ]] && echo "message=${message}"
else
  echo "$body"
  if [[ "$body" == *'"valid":true'* || "$body" == *'"valid": true'* ]]; then
    exit 0
  fi
fi

if [[ "$http_status" =~ ^5 ]]; then
  exit 2
fi

exit 1
