#!/usr/bin/env zsh
# Browser helpers — sourced by init.zsh

_BROWSER_DIR="${0:A:h}"

chrome-cdp() {
  "$_BROWSER_DIR/chrome-cdp.sh" "$@"
}

chrome() {
  open -a "Google Chrome" "$@"
}

firefox() {
  open -a "Firefox" "$@"
}

edge() {
  open -a "Microsoft Edge" "$@"
}

safari() {
  open -a "Safari" "$@"
}
