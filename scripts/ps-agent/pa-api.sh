# prompt_agent — tenant-API helpers
#
# Wraps the same endpoints the agent itself talks to (see
# src/background_processes/inspection_policy.py and src/common/client.py in
# the ps-agent repo).  Credentials come from the local MDM plist or the
# agent's config.toml; `app-id` header is what the agent sends.
#
# Usage:
#   pa-api whoami                       # show resolved domain + masked app-id
#   pa-api get-apps                     # GET /api/protect-native-apps/get_apps
#   pa-api get-secrets [domain]         # GET /api/protect-native-apps/get_secrets_policy
#   pa-api heartbeat                    # POST /api/protect-native-apps/heartbeat
#   pa-api apps-summary                 # histogram of apps in get_apps
#   pa-api apps-by-name <app>           # list URL patterns for one app
#   pa-api match <url>                  # which app would the agent classify a URL as?
#   pa-api genai-check <domain>...      # run the bin/check-domain-in-genai-list.sh helper
#   pa-api curl <path> [curl args...]   # authed curl to https://${domain}<path>
#   pa-api env                          # print export lines for PROMPT_API_DOMAIN / PROMPT_API_KEY
#
# All subcommands accept --raw to skip jq pretty-printing.

# Make the standalone script in ./bin reachable on PATH (also lets you run
# `check-domain-in-genai-list.sh` directly without the wrapper).
_PA_API_DIR="${0:A:h}"
case ":$PATH:" in
  *":$_PA_API_DIR/bin:"*) ;;
  *) export PATH="$_PA_API_DIR/bin:$PATH" ;;
esac

# ── credentials resolution ───────────────────────────────────────────────
# Resolution order (matches src/common/config.py:94 get_platform_config):
#   1) Env: PROMPT_API_DOMAIN / PROMPT_API_KEY (override everything)
#   2) MDM plist: /Library/Managed Preferences/com.prompt.security.agent.plist
#   3) Agent config (INI-style, chflags-hidden): /Library/Application Support/Prompt/config.toml
_pa_api_load_creds() {
  local plist="/Library/Managed Preferences/com.prompt.security.agent.plist"
  local cfg="/Library/Application Support/Prompt/config.toml"

  PA_API_DOMAIN="${PROMPT_API_DOMAIN:-}"
  PA_API_KEY="${PROMPT_API_KEY:-}"
  PA_API_SOURCE="${PROMPT_API_DOMAIN:+env}"

  if [[ -z "$PA_API_DOMAIN" && -r "$plist" ]]; then
    PA_API_DOMAIN="$(/usr/libexec/PlistBuddy -c 'Print :domain' "$plist" 2>/dev/null)"
    PA_API_KEY="$(/usr/libexec/PlistBuddy -c 'Print :apiKey' "$plist" 2>/dev/null)"
    [[ -n "$PA_API_DOMAIN" ]] && PA_API_SOURCE="mdm-plist"
  fi

  if [[ -z "$PA_API_DOMAIN" ]]; then
    # config.toml is hidden + read-protected; needs sudo.
    local content
    content=$(sudo cat "$cfg" 2>/dev/null) || return 1
    PA_API_DOMAIN="$(printf '%s\n' "$content" | awk -F'=' '
      /^\[/{section=$0; next}
      section=="[app]" && $1 ~ /^[[:space:]]*domain[[:space:]]*$/ {
        sub(/^[[:space:]]*/,"",$2); sub(/[[:space:]]*$/,"",$2);
        gsub(/^"|"$/,"",$2); print $2; exit
      }')"
    PA_API_KEY="$(printf '%s\n' "$content" | awk -F'=' '
      /^\[/{section=$0; next}
      section=="[app]" && $1 ~ /^[[:space:]]*api_key[[:space:]]*$/ {
        sub(/^[[:space:]]*/,"",$2); sub(/[[:space:]]*$/,"",$2);
        gsub(/^"|"$/,"",$2); print $2; exit
      }')"
    [[ -n "$PA_API_DOMAIN" ]] && PA_API_SOURCE="config.toml"
  fi

  [[ -n "$PA_API_DOMAIN" && -n "$PA_API_KEY" ]]
}

# ── core curl wrappers ───────────────────────────────────────────────────
_pa_api_curl() {
  _pa_api_load_creds || { echo "pa-api: failed to resolve domain/api_key" >&2; return 2; }
  curl -fsS "https://${PA_API_DOMAIN}$1" \
    -H "app-id: ${PA_API_KEY}" \
    -H "content-type: application/json" \
    "${@:2}"
}

# Pretty by default, raw with --raw or PA_API_RAW=1
_pa_api_format() {
  if [[ "$PA_API_RAW" == "1" || "${1:-}" == "--raw" ]]; then
    cat
  elif command -v jq >/dev/null; then
    jq .
  else
    cat
  fi
}

# ── subcommands ──────────────────────────────────────────────────────────
pa-api() {
  local cmd="${1:-}"; shift 2>/dev/null

  local raw=0
  if [[ "${1:-}" == "--raw" ]]; then raw=1; shift; fi
  PA_API_RAW="$raw"

  case "$cmd" in
    whoami|env)
      _pa_api_load_creds || { echo "pa-api: no credentials found" >&2; return 2; }
      if [[ "$cmd" == "env" ]]; then
        printf 'export PROMPT_API_DOMAIN=%q\n' "$PA_API_DOMAIN"
        printf 'export PROMPT_API_KEY=%q\n'    "$PA_API_KEY"
      else
        printf 'domain : %s\n'  "$PA_API_DOMAIN"
        printf 'app-id : %s…%s\n' "${PA_API_KEY:0:6}" "${PA_API_KEY: -4}"
        printf 'source : %s\n'  "$PA_API_SOURCE"
      fi
      ;;

    get-apps)
      _pa_api_curl "/api/protect-native-apps/get_apps" "$@" | _pa_api_format
      ;;

    get-secrets)
      # Optional domain query — secrets policy is per-tenant but accepts a
      # ?domain= filter on some deployments; passthrough as-is.
      local q=""
      [[ -n "${1:-}" ]] && q="?domain=$(printf '%s' "$1" | jq -sRr @uri)"
      _pa_api_curl "/api/protect-native-apps/get_secrets_policy${q}" | _pa_api_format
      ;;

    heartbeat)
      _pa_api_curl "/api/protect-native-apps/heartbeat" \
        -X POST -d '{"configTimestamps":{}}' | _pa_api_format
      ;;

    apps-summary)
      _pa_api_curl "/api/protect-native-apps/get_apps" \
        | jq -r 'to_entries | group_by(.value) | map({app: .[0].value, count: length}) | sort_by(-.count) | .[] | "\(.count)\t\(.app)"' \
        | column -t -s "$(printf '\t')"
      ;;

    apps-by-name)
      [[ -z "${1:-}" ]] && { echo "usage: pa-api apps-by-name <app-name>" >&2; return 1; }
      _pa_api_curl "/api/protect-native-apps/get_apps" \
        | jq -r --arg name "$1" 'to_entries[] | select(.value == $name) | .key'
      ;;

    match)
      [[ -z "${1:-}" ]] && { echo "usage: pa-api match <url>" >&2; return 1; }
      local url="$1"
      _pa_api_curl "/api/protect-native-apps/get_apps" \
        | jq -r --arg url "$url" '
            to_entries
            | (map(select(.key == $url)) + map(select(.key != $url and ($url | test(.key)))))
            | .[0] // empty
            | "\(.value)\t\(.key)"' \
        | { read -r line; if [[ -n "$line" ]]; then
              printf 'app    : %s\npattern: %s\n' "${line%%	*}" "${line#*	}"
            else
              echo "no match — should_inspect_app($url) would return None" >&2; return 3
            fi; }
      ;;

    genai-check)
      [[ -z "${1:-}" ]] && { echo "usage: pa-api genai-check <domain> [domain...]" >&2; return 1; }
      _pa_api_load_creds || { echo "pa-api: no credentials found" >&2; return 2; }
      PROMPT_API_DOMAIN="$PA_API_DOMAIN" PROMPT_API_KEY="$PA_API_KEY" \
        "$_PA_API_DIR/bin/check-domain-in-genai-list.sh" "$@"
      ;;

    curl)
      [[ -z "${1:-}" ]] && { echo "usage: pa-api curl <path> [curl-args...]" >&2; return 1; }
      _pa_api_curl "$@"
      ;;

    ""|-h|--help|help)
      cat <<EOF
pa-api — tenant API helpers (uses agent's domain + app-id)

  whoami                  show resolved domain + masked app-id + source
  env                     print export lines for PROMPT_API_* (eval-friendly)
  get-apps                GET /api/protect-native-apps/get_apps  (INSPECT_URLS_MAP)
  get-secrets [domain]    GET /api/protect-native-apps/get_secrets_policy
  heartbeat               POST /api/protect-native-apps/heartbeat
  apps-summary            histogram of apps in get_apps
  apps-by-name <app>      URL patterns mapped to a given app
  match <url>             which app would should_inspect_app(url) return?
  genai-check <domain>... run bin/check-domain-in-genai-list.sh
  curl <path> [args...]   generic authed curl to https://\${domain}<path>

Add --raw before args to skip jq formatting.
EOF
      ;;

    *)
      echo "pa-api: unknown subcommand '$cmd' (try 'pa-api help')" >&2
      return 1
      ;;
  esac
}

_pa_api() {
  compadd whoami env get-apps get-secrets heartbeat \
          apps-summary apps-by-name match genai-check curl help
}
compdef _pa_api pa-api
