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

# Interactive elevated PowerShell on the Windows VM.
# SSH sessions already run at High Mandatory Level (the key is in the guest's
# administrators_authorized_keys). sshd's DefaultShell is set to powershell.exe,
# so a plain `ssh` gets a real shell session with a ConPTY — which is what
# PSReadLine needs for history and arrow keys. Running `ssh host powershell`
# instead creates an *exec* session with no ConPTY, and arrow keys come through
# as raw escape sequences (^[[A).
#
# Because DefaultShell is PowerShell, any cmd.exe syntax sent over ssh
# (`a & b`, `dir /b`, %errorlevel%) must be wrapped in `cmd /c "..."`.
#
#   winvm                   interactive elevated PowerShell prompt
#   winvm <cmd...>          run one PowerShell command and exit
winvm() {
  emulate -L zsh
  local target="${WINDRV_USER:-ariel}@${WINDRV_HOST:-192.168.64.3}"
  if (( $# )); then
    ssh -o ConnectTimeout=10 "$target" "powershell -NoProfile -Command $*"
  else
    ssh -t "$target"
  fi
}

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
      local tail_n="${3:-40}"
      print "capturing ${secs}s of kernel output matching *$name* ..."
      # all PowerShell: no cmd.exe & chaining, which breaks under DefaultShell
      local ps="Start-Process -FilePath '$dbg' -ArgumentList '--accepteula','--no-banner','-k','-v','-i','*$name*','--clock-ms' -RedirectStandardOutput '$out' -NoNewWindow;"
      ps+=" Start-Sleep -Seconds $secs;"
      ps+=" & '$dbg' --stop | Out-Null;"
      ps+=" if ((Get-Item '$out').Length -eq 0) { 'no output captured - was the VM idle? DbgPrint only fires on file creates' }"
      ps+=" else { Get-Content '$out' -Tail $tail_n }"
      ssh -o ConnectTimeout=10 "$target" "powershell -NoProfile -Command \"$ps\""
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
