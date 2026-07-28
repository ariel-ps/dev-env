#!/usr/bin/env zsh
# pa-pac — toggle the Prompt Security PAC proxy on Wi-Fi, sourced by init.zsh
#
#   pa-pac enable    set the PAC url on Wi-Fi and turn auto-proxy on
#   pa-pac disable   turn auto-proxy off on Wi-Fi (PAC url stays configured)
#   pa-pac status    show current auto-proxy url/state on Wi-Fi

_PA_PAC_SERVICE="Wi-Fi"
_PA_PAC_URL="https://us.prompt.security/api/protect-native-apps/pacs/3636/proxy.pac"

pa-pac() {
  local cmd="${1:-}"
  command -v networksetup >/dev/null 2>&1 \
    || { echo "pa-pac: networksetup not found (macOS only)" >&2; return 1; }

  case "$cmd" in
    enable)
      networksetup -setautoproxyurl "$_PA_PAC_SERVICE" "$_PA_PAC_URL" \
        && networksetup -setautoproxystate "$_PA_PAC_SERVICE" on \
        && echo "pa-pac: enabled on $_PA_PAC_SERVICE ($_PA_PAC_URL)"
      ;;
    disable)
      networksetup -setautoproxystate "$_PA_PAC_SERVICE" off \
        && echo "pa-pac: disabled on $_PA_PAC_SERVICE"
      ;;
    status)
      networksetup -getautoproxyurl "$_PA_PAC_SERVICE"
      ;;
    *)
      echo "usage: pa-pac <enable|disable|status>" >&2
      return 1
      ;;
  esac
}
