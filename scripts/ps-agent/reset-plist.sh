# Safari extension plist reset helper
# Wipes the user-side + MDM-managed plists for the Prompt Security Safari
# extension — used when debugging hidden API-key inputs / config caching.
reset-plist() {
  local APP_GROUP_PLIST="$HOME/Library/Group Containers/group.J7M9U73T5B.com.prompt.security.safari/Library/Preferences/J7M9U73T5B.com.prompt.security.safari.plist"
  local EXT_PREFS="$HOME/Library/Containers/com.prompt.security.Safari-Extension.Extension/Data/Library/Preferences/com.prompt.security.Safari-Extension.Extension.plist"
  local APP_PREFS="$HOME/Library/Containers/com.prompt.security.Safari-Extension/Data/Library/Preferences/com.prompt.security.Safari-Extension.plist"
  local MDM_PLIST="/Library/Managed Preferences/com.prompt.security.Safari-Extension.Extension.plist"
  local MDM_BACKUP="/tmp/mdm-prompt-extension.plist.bak"

  case "${1:-user}" in
    user)
      for f in "$APP_GROUP_PLIST" "$EXT_PREFS" "$APP_PREFS"; do
        if [[ -f "$f" ]]; then
          rm "$f" && echo "✓ deleted: $f"
        else
          echo "skip (absent): $f"
        fi
      done
      if [[ -f "$MDM_PLIST" ]]; then
        sudo rm "$MDM_PLIST" && echo "✓ deleted: $MDM_PLIST"
      else
        echo "skip (absent): $MDM_PLIST"
      fi
      echo "→ Quit Safari fully (⌘Q) and reopen to test."
      ;;
    mdm-off)
      if [[ -f "$MDM_PLIST" ]]; then
        sudo mv "$MDM_PLIST" "$MDM_BACKUP" && echo "✓ moved MDM plist → $MDM_BACKUP"
        echo "→ Quit Safari fully (⌘Q) and reopen. JumpCloud may re-push within minutes."
      else
        echo "skip (absent): $MDM_PLIST"
      fi
      ;;
    mdm-on)
      if [[ -f "$MDM_BACKUP" ]]; then
        sudo mv "$MDM_BACKUP" "$MDM_PLIST" && echo "✓ restored MDM plist"
      else
        echo "skip (no backup): $MDM_BACKUP"
      fi
      ;;
    all)     reset-plist user && reset-plist mdm-off ;;
    status)
      for f in "$APP_GROUP_PLIST" "$EXT_PREFS" "$APP_PREFS" "$MDM_PLIST" "$MDM_BACKUP"; do
        if [[ -f "$f" ]]; then echo "exists: $f"; else echo "absent: $f"; fi
      done
      ;;
    *) echo "usage: reset-plist {user|mdm-off|mdm-on|all|status}" >&2; return 1 ;;
  esac
}
_reset_plist() { compadd user mdm-off mdm-on all status }
compdef _reset_plist reset-plist
