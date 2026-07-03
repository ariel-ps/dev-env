# intune — Microsoft Intune Graph API helpers
#
# Queries device management data via Microsoft Graph API
# (https://graph.microsoft.com/v1.0/deviceManagement/).
#
# Credentials (application permissions, client-credentials OAuth2 flow):
#   1) Env: INTUNE_TENANT_ID + INTUNE_CLIENT_ID + INTUNE_CLIENT_SECRET
#   2) File: ~/.config/intune/credentials (KEY=VALUE lines)
#
# Required API permissions (application type, admin-consented):
#   DeviceManagementManagedDevices.Read.All
#   DeviceManagementManagedDevices.PrivilegedOperations.All  (sync)
#
# Usage:
#   intune whoami                        # show resolved creds + token check
#   intune device [name]                 # full device record (default: hostname)
#   intune devices [--os macOS|Windows]  # list all managed devices
#   intune compliance [name]             # compliance state + last sync
#   intune sync [name]                   # trigger MDM sync
#   intune profiles [name]               # config profile states on a device
#   intune curl <path> [curl args...]    # raw authed call to graph.microsoft.com

_INTUNE_TOKEN=""
_INTUNE_TOKEN_EXP=0

_intune_load_creds() {
  INTUNE_TENANT_ID="${INTUNE_TENANT_ID:-}"
  INTUNE_CLIENT_ID="${INTUNE_CLIENT_ID:-}"
  INTUNE_CLIENT_SECRET="${INTUNE_CLIENT_SECRET:-}"

  if [[ -z "$INTUNE_TENANT_ID" ]]; then
    local creds_file="${HOME}/.config/intune/credentials"
    if [[ -r "$creds_file" ]]; then
      while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        local key="${line%%=*}" val="${line#*=}"
        key="${key#"${key%%[! ]*}"}" key="${key%"${key##*[! ]}"}"
        case "$key" in
          INTUNE_TENANT_ID)     INTUNE_TENANT_ID="$val" ;;
          INTUNE_CLIENT_ID)     INTUNE_CLIENT_ID="$val" ;;
          INTUNE_CLIENT_SECRET) INTUNE_CLIENT_SECRET="$val" ;;
        esac
      done < "$creds_file"
    fi
  fi

  [[ -n "$INTUNE_TENANT_ID" && -n "$INTUNE_CLIENT_ID" && -n "$INTUNE_CLIENT_SECRET" ]]
}

_intune_token() {
  local now; now=$(date +%s)
  if [[ -n "$_INTUNE_TOKEN" && "$now" -lt "$_INTUNE_TOKEN_EXP" ]]; then
    printf '%s' "$_INTUNE_TOKEN"
    return 0
  fi

  _intune_load_creds || { echo "intune: credentials not found" >&2; return 2; }

  local resp
  resp=$(curl -fsS \
    "https://login.microsoftonline.com/${INTUNE_TENANT_ID}/oauth2/v2.0/token" \
    --data-urlencode "client_id=${INTUNE_CLIENT_ID}" \
    --data-urlencode "client_secret=${INTUNE_CLIENT_SECRET}" \
    --data-urlencode "scope=https://graph.microsoft.com/.default" \
    --data-urlencode "grant_type=client_credentials") || {
    echo "intune: token request failed" >&2; return 2
  }

  _INTUNE_TOKEN=$(printf '%s' "$resp" | jq -r '.access_token // empty')
  local expires_in; expires_in=$(printf '%s' "$resp" | jq -r '.expires_in // 3600')
  _INTUNE_TOKEN_EXP=$(( now + expires_in - 60 ))

  [[ -n "$_INTUNE_TOKEN" ]] || { echo "intune: no token in response" >&2; return 2; }
  printf '%s' "$_INTUNE_TOKEN"
}

_intune_graph() {
  local path="$1"; shift
  local token; token=$(_intune_token) || return $?
  curl -fsS "https://graph.microsoft.com/v1.0${path}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "$@"
}

_intune_device_id() {
  local name="${1:-$(hostname -s)}"
  _intune_graph "/deviceManagement/managedDevices?\$filter=deviceName eq '${name}'&\$select=id,deviceName" \
    | jq -r '.value[0].id // empty'
}

_intune_fmt() {
  if command -v jq >/dev/null; then jq .; else cat; fi
}

intune() {
  local cmd="${1:-}"; shift 2>/dev/null

  case "$cmd" in
    whoami)
      _intune_load_creds || { echo "intune: no credentials found" >&2; return 2; }
      printf 'tenant  : %s\n' "$INTUNE_TENANT_ID"
      printf 'client  : %s…%s\n' "${INTUNE_CLIENT_ID:0:8}" "${INTUNE_CLIENT_ID: -4}"
      printf 'secret  : %s…%s\n' "${INTUNE_CLIENT_SECRET:0:4}" "${INTUNE_CLIENT_SECRET: -4}"
      _intune_token >/dev/null && printf 'token   : ok\n' || printf 'token   : FAILED\n'
      ;;

    device)
      local name="${1:-$(hostname -s)}"
      _intune_graph "/deviceManagement/managedDevices?\$filter=deviceName eq '${name}'" \
        | jq '.value[0]'
      ;;

    devices)
      local filter=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --os) filter="operatingSystem eq '$2'"; shift 2 ;;
          *) shift ;;
        esac
      done
      local q="/deviceManagement/managedDevices?\$select=deviceName,operatingSystem,complianceState,lastSyncDateTime,userPrincipalName"
      [[ -n "$filter" ]] && q+="&\$filter=${filter}"
      _intune_graph "$q" \
        | jq -r '.value[] | "\(.complianceState)\t\(.operatingSystem)\t\(.deviceName)\t\(.userPrincipalName)"' \
        | column -t -s "$(printf '\t')"
      ;;

    compliance)
      local name="${1:-$(hostname -s)}"
      local id; id=$(_intune_device_id "$name") || return $?
      [[ -z "$id" ]] && { echo "intune: device '$name' not found" >&2; return 3; }
      _intune_graph "/deviceManagement/managedDevices/${id}?\$select=deviceName,complianceState,lastSyncDateTime,userPrincipalName,osVersion,model" \
        | jq '{device: .deviceName, compliance: .complianceState, lastSync: .lastSyncDateTime, user: .userPrincipalName, os: .osVersion, model: .model}'
      ;;

    sync)
      local name="${1:-$(hostname -s)}"
      local id; id=$(_intune_device_id "$name") || return $?
      [[ -z "$id" ]] && { echo "intune: device '$name' not found" >&2; return 3; }
      _intune_graph "/deviceManagement/managedDevices/${id}/syncDevice" -X POST -d '{}' \
        && echo "sync triggered for '${name}'" \
        || { echo "intune: sync failed" >&2; return 2; }
      ;;

    profiles)
      local name="${1:-$(hostname -s)}"
      local id; id=$(_intune_device_id "$name") || return $?
      [[ -z "$id" ]] && { echo "intune: device '$name' not found" >&2; return 3; }
      _intune_graph "/deviceManagement/managedDevices/${id}/deviceConfigurationStates" \
        | jq -r '.value[] | "\(.state)\t\(.displayName)"' \
        | column -t -s "$(printf '\t')"
      ;;

    app-status)
      local target_name="${1:-$(hostname -s)}"
      echo "Fetching app install states for '${target_name}'..." >&2
      local apps
      apps=$(_intune_graph "/deviceAppManagement/mobileApps?\$select=id,displayName,publishingState" \
        | jq -r '.value[] | select(.publishingState == "published") | "\(.id)\t\(.displayName)"')

      local header=0
      while IFS=$'\t' read -r app_id app_name; do
        local resp
        resp=$(_intune_graph "/deviceAppManagement/mobileApps/${app_id}/deviceStatuses" 2>/dev/null) || continue
        local row
        row=$(printf '%s' "$resp" | jq -r --arg dev "$target_name" \
          '.value[] | select(.deviceName == $dev) | "\(.installState)\t\(.errorCode)\t\(.deviceName)"' 2>/dev/null)
        if [[ -n "$row" ]]; then
          [[ $header -eq 0 ]] && { printf 'installState\terrorCode\tapp\n'; header=1; }
          while IFS= read -r line; do
            printf '%s\t%s\n' "$line" "$app_name"
          done <<< "$row"
        fi
      done <<< "$apps" | column -t -s $'\t'

      [[ $header -eq 0 ]] && echo "No install state records found for '${target_name}' — device may not have checked in yet."
      ;;

    curl)
      [[ -z "${1:-}" ]] && { echo "usage: intune curl <path> [curl-args...]" >&2; return 1; }
      _intune_graph "$@" | _intune_fmt
      ;;

    ""|-h|--help|help)
      cat <<'EOF'
intune — Microsoft Intune Graph API helpers

  whoami                         show tenant/client IDs + token check
  device [name]                  full device record (default: this machine)
  devices [--os macOS|Windows]   list managed devices (compliance/OS/name/user)
  compliance [name]              compliance state + last sync (default: this machine)
  sync [name]                    trigger MDM sync (default: this machine)
  profiles [name]                config profile states on a device
  app-status [name]              actual install state per app on a device
  curl <path> [args...]          raw authed call to graph.microsoft.com<path>

Credentials (client-credentials OAuth2 flow):
  1) Env: INTUNE_TENANT_ID + INTUNE_CLIENT_ID + INTUNE_CLIENT_SECRET
  2) File: ~/.config/intune/credentials (KEY=VALUE lines)

Required API permissions (application type, admin-consented):
  DeviceManagementManagedDevices.Read.All
  DeviceManagementManagedDevices.PrivilegedOperations.All  (for sync)
  DeviceManagementApps.Read.All                            (for app-status)
EOF
      ;;

    *)
      echo "intune: unknown subcommand '$cmd' (try 'intune help')" >&2
      return 1
      ;;
  esac
}

_intune_complete() {
  compadd whoami device devices compliance sync profiles app-status curl help
}
compdef _intune_complete intune
