# ps-known-site — query the global.prompt.security UI API to check whether a
# URL matches any "Known Sites" rule (genAi catalogue + tenant custom rules).
#
# Endpoint:  POST /api/gen-ai/known-sites/test-url
# Auth:      fronteggSessionToken cookie from a logged-in browser session
#
# Usage:
#   export PROMPT_JWT='<fronteggSessionToken value>'
#   ps-known-site https://browser-intake-datadoghq.com/api/v2/rum
#
# Get a fresh JWT:
#   1. Open https://global.prompt.security in browser (logged in)
#   2. DevTools → Application → Cookies → fronteggSessionToken → copy value
ps-known-site() {
  if [ -z "${PROMPT_JWT:-}" ]; then
    echo "[ps-known-site] error: missing environment variable PROMPT_JWT" >&2
    echo "  → export PROMPT_JWT='<fronteggSessionToken value>'" >&2
    echo "  → get it from https://global.prompt.security (DevTools → Cookies)" >&2
    return 1
  fi

  local url="${1:-}"
  if [ -z "$url" ]; then
    echo "usage: ps-known-site <url>" >&2
    return 2
  fi

  curl -fsS 'https://global.prompt.security/api/gen-ai/known-sites/test-url' \
    -H 'accept: application/json' \
    -H 'content-type: application/json' \
    -b "fronteggSessionToken=$PROMPT_JWT" \
    -H 'origin: https://global.prompt.security' \
    --data-raw "$(jq -nc --arg u "$url" '{url:$u}')" \
    | jq '.'
}
