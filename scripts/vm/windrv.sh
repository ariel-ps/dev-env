#!/usr/bin/env zsh
# Windows kernel driver dev loop against the UTM Windows VM — sourced by init.zsh.
#
# Drives mk.ps1 inside the VM over SSH. The SSH key lives in the guest's
# administrators_authorized_keys, so sessions get a full admin token — pnputil
# and fltmc load work without any UAC dance.
#
#   windrv                  status (default)
#   windrv build            compile + sign only
#   windrv deploy           build -> pnputil install -> fltmc load
#   windrv status           service + filter + instances + driver packages
#   windrv unload           fltmc unload, leave installed
#   windrv remove           unload + delete the driver package
#   windrv sync             scp local sources to the VM, then deploy
#   windrv log [seconds]    capture kernel DbgPrint output (default 10s)
#   windrv sh [cmd...]      run a command in the VM (interactive shell if none)
#
# Notes:
#   - Guest has no outbound internet by default; `vm_network_fix` sets up the
#     CONNECT proxy if a build step needs to download something.
#   - `log` needs the debug print filter mask set, see the tutorial in dev-notes.
#
# Overridable (export before calling):
#   WINDRV_HOST=192.168.64.3   WINDRV_USER=ariel
#   WINDRV_DIR='C:\dev\hellofs'   WINDRV_NAME=hellofs
#   WINDRV_SRC=~/Documents/projects/dev-notes/windows-kernel/minifilter-hello-world

windrv() {
  emulate -L zsh
  local host="${WINDRV_HOST:-192.168.64.3}"
  local user="${WINDRV_USER:-ariel}"
  local dir="${WINDRV_DIR:-C:\\dev\\hellofs}"
  local name="${WINDRV_NAME:-hellofs}"
  local src="${WINDRV_SRC:-$HOME/Documents/projects/dev-notes/windows-kernel/minifilter-hello-world}"
  local target="$user@$host"
  local action="${1:-status}"

  # -File wants an absolute path: cd does not persist across ssh invocations
  local -a ps_run=(powershell -NoProfile -ExecutionPolicy Bypass -File "$dir\\mk.ps1")

  case "$action" in
    build|deploy|status|unload|remove)
      ssh -o ConnectTimeout=10 "$target" "$ps_run $action"
      ;;

    sync)
      [[ -d $src ]] || { print -u2 "windrv: no source dir: $src"; return 1 }
      # scp needs forward slashes on the remote path, mk.ps1 needs backslashes
      local remote_dir="${dir//\\//}"
      scp -q "$src"/*.c "$src"/*.inf "$src"/*.vcxproj "$src"/mk.ps1 \
        "$target:$remote_dir/" || return 1
      print "synced $src -> $host:$dir"
      ssh -o ConnectTimeout=10 "$target" "$ps_run deploy"
      ;;

    log)
      local secs="${2:-10}"
      local dbg='C:\tools\DebugView\dbgviewcli64a.exe'
      local out="C:\\dev\\${name}-dbg.log"
      print "capturing ${secs}s of kernel output matching *$name* ..."
      ssh -o ConnectTimeout=10 "$target" \
        "start /b cmd /c \"$dbg --accepteula --no-banner -k -v -i *$name* --clock-ms > $out 2>&1\" & ping -n $((secs + 1)) 127.0.0.1 > nul & $dbg --stop > nul 2>&1"
      ssh -o ConnectTimeout=10 "$target" "type $out"
      ;;

    sh)
      shift
      if (( $# )); then
        ssh -o ConnectTimeout=10 "$target" "$@"
      else
        ssh "$target"
      fi
      ;;

    -h|--help|help)
      print "usage: windrv [build|deploy|status|unload|remove|sync|log [secs]|sh [cmd]]"
      ;;

    *)
      print -u2 "windrv: unknown action '$action' (try: windrv help)"
      return 1
      ;;
  esac
}
