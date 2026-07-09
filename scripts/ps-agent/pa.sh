# prompt_agent helper
_pa_print_hardening_guard_version() {
  local hardening_logs="$1"
  local service="endpoint-security.com.promptsecurity.PSAgentMacGuardHost.PSAgentMacGuardExtension"
  local program_path info_plist version build sha
  local -a info_plists

  program_path=$(sudo launchctl print "system/$service" 2>/dev/null | awk -F' = ' '/^[[:space:]]*program = / {print $2; exit}')
  if [[ -n "$program_path" ]]; then
    info_plist="${program_path:h:h}/Info.plist"
  fi

  if [[ -z "$info_plist" || ! -f "$info_plist" ]]; then
    info_plists=(/Library/SystemExtensions/*/com.promptsecurity.PSAgentMacGuardHost.PSAgentMacGuardExtension.systemextension/Contents/Info.plist(N))
    (( ${#info_plists} )) && info_plist="${info_plists[1]}"
  fi

  if [[ -n "$info_plist" ]]; then
    version=$(sudo /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null)
    build=$(sudo /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist" 2>/dev/null)
  fi

  sha=$(sudo grep -a 'agent_sha=' "$hardening_logs" 2>/dev/null | tail -1 | sed -E 's/.*agent_sha=([^] ]+).*/\1/')

  if [[ -n "$version$build$sha" ]]; then
    printf 'hardening guard:'
    [[ -n "$version" ]] && printf ' version=%s' "$version"
    [[ -n "$build" ]] && printf ' build=%s' "$build"
    [[ -n "$sha" ]] && printf ' sha=%s' "$sha"
    printf '\n'
  else
    echo "hardening guard: version unavailable" >&2
  fi
}

pa() {
  local bin=/usr/local/bin/prompt_security/prompt_agent
  local plist=/Library/LaunchDaemons/com.prompt.service.plist
  local logs=/Users/Shared/.prompt_security/service_logs.log
  local hardening_logs=/Users/Shared/.prompt_security/hardening_audit.log
  case "$1" in
    status)    sudo "$bin" status ;;
    logout)    sudo "$bin" logout ;;
    uninstall) sudo "$bin" uninstall ;;
    start)     sudo launchctl load "$plist" ;;
    stop)      sudo launchctl unload "$plist" ;;
    restart)   sudo launchctl unload "$plist" && sudo launchctl load "$plist" ;;
    logs)      sudo tail -f "$logs" ;;
    hardening-status)
      local hardening_output
      hardening_output=$(sudo "$bin" hardening status 2>&1)
      local status_rc=$?
      if [[ -n "$hardening_output" ]]; then
        printf '%s\n' "$hardening_output" | sed '/Agent version:/d'
      fi
      _pa_print_hardening_guard_version "$hardening_logs"
      return "$status_rc"
      ;;
    hardening-logs) sudo cat "$hardening_logs" ;;
    edit)
      local cfg="/Library/Application Support/Prompt/config.toml"
      (
        trap '
          sudo chmod 444 "/Library/Application Support/Prompt/config.toml"
          sudo chflags schg "/Library/Application Support/Prompt/config.toml"
          sudo chflags hidden "/Library/Application Support/Prompt/config.toml"
        ' EXIT INT TERM HUP
        sudo chflags noschg "$cfg"
        sudo chmod u+w "$cfg"
        sudo chflags nohidden "$cfg"
        sudo nano "$cfg"
      )
      ;;
    *) echo "usage: pa {status|logout|uninstall|start|stop|restart|logs|hardening-status|hardening-logs|edit}" >&2; return 1 ;;
  esac
}
_pa() { compadd status logout uninstall start stop restart logs hardening-status hardening-logs edit }
compdef _pa pa
alias par='pa restart'
