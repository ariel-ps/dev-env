# prompt_agent helper
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
    *) echo "usage: pa {status|logout|uninstall|start|stop|restart|logs|hardening-logs|edit}" >&2; return 1 ;;
  esac
}
_pa() { compadd status logout uninstall start stop restart logs hardening-logs edit }
compdef _pa pa
alias par='pa restart'
