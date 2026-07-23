#!/usr/bin/env zsh
# Dev VM connectivity — sourced by init.zsh. Two independent scenarios:
#
# A) App-level HTTPS proxy (Windows VM, UTM/Parallels NAT). The VM can ping out
#    and reach the Mac host on its private subnet, but outbound TCP/443 to public
#    IPs is blocked. Fix: a CONNECT-tunnel proxy on the Mac
#    (bin/connect-tunnel-proxy.py) the VM points HTTPS_PROXY at.
#
#   vm_network_fix            ensure the proxy is up, then diagnose the chain
#   vm_network_fix status     is the proxy listening? on which interface?
#   vm_network_fix stop       stop the proxy
#   vm_network_fix diag       reachability checks only (VM ping, proxy bind)
#
# B) L3 VPN-share (macOS VM reaching a private VPC over the host's corp VPN).
#    The VM resolves an internal host to a private range (e.g. 10.66/16) but has
#    no route to it; the Mac is on the VPN but does not forward the VM's subnet.
#    Fix: enable IP forwarding + split pf NAT — VPC-bound traffic out the live
#    VPN utun, everything else out the real uplink so the VM keeps public
#    internet (a single `to any -> utun` rule black-holes public traffic on a
#    split-tunnel VPN). The utun index changes across VPN reconnects, so it is
#    auto-detected by which interface currently routes to the VPC.
#
#   vm_network_fix vpn        detect VPN utun, enable forwarding + pf NAT (sudo)
#   vm_network_fix vpn-status forwarding state, detected utun, active NAT rule
#   vm_network_fix vpn-stop   flush the NAT anchor + disable forwarding (sudo)
#
#   Non-persistent: rerun `vpn` after host reboot / VPN reconnect / utun change.
#
# Overridable (export before calling):
#   VM_HOST=192.168.64.3   VM_GATEWAY=192.168.64.1   VM_PROXY_PORT=8888
#   VPC_CIDR=10.66.0.0/16  VM_SUBNET=192.168.64.0/24  VM_NAT_ANCHOR=ps-vm-vpn

_VM_DIR="${0:A:h}"

vm_network_fix() {
  emulate -L zsh
  local vm_host="${VM_HOST:-192.168.64.3}"
  local gateway="${VM_GATEWAY:-192.168.64.1}"
  local port="${VM_PROXY_PORT:-8888}"
  local proxy="$_VM_DIR/bin/connect-tunnel-proxy.py"
  local logf="${TMPDIR:-/tmp}/vm-connect-proxy.log"
  local pidf="${TMPDIR:-/tmp}/vm-connect-proxy.pid"
  # Scenario B (L3 VPN-share) knobs.
  local vpc_cidr="${VPC_CIDR:-10.66.0.0/16}"
  local vm_subnet="${VM_SUBNET:-192.168.64.0/24}"
  local anchor="${VM_NAT_ANCHOR:-ps-vm-vpn}"

  _vm_proxy_listen_line() { lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | tail -n +2; }
  _vm_proxy_pid()         { _vm_proxy_listen_line | awk 'NR==1{print $2}'; }
  _vm_proxy_bound_all()   { _vm_proxy_listen_line | grep -q '\*:'"$port"; }

  _vm_status() {
    local line; line=$(_vm_proxy_listen_line)
    if [[ -z "$line" ]]; then
      echo "proxy: not running (nothing listening on :$port)"
      return 1
    fi
    echo "proxy: listening on :$port (pid $(_vm_proxy_pid))"
    if _vm_proxy_bound_all; then
      echo "  bound to *:$port — reachable from the VM ✓"
    else
      echo "  ⚠ bound to 127.0.0.1 only — VM cannot reach it."
      echo "    Set VM_PROXY_HOST=0.0.0.0 and restart: vm_network_fix stop && vm_network_fix"
    fi
    return 0
  }

  _vm_diag() {
    echo "VM host       : $vm_host"
    echo "Mac gateway   : $gateway (proxy target from VM: http://$gateway:$port)"
    if ping -c1 -t2 "$vm_host" >/dev/null 2>&1; then
      echo "VM reachable  : yes (ping ok)"
    else
      echo "VM reachable  : NO — VM off, wrong IP, or NAT down. Check the VM is running."
    fi
    _vm_status
  }

  _vm_stop() {
    local pid; pid=$(_vm_proxy_pid)
    if [[ -z "$pid" ]]; then
      echo "proxy: not running"
      [[ -f "$pidf" ]] && rm -f "$pidf"
      return 0
    fi
    kill "$pid" 2>/dev/null && echo "proxy: stopped (pid $pid)"
    rm -f "$pidf"
  }

  _vm_start() {
    if _vm_proxy_listen_line >/dev/null && [[ -n "$(_vm_proxy_listen_line)" ]]; then
      echo "proxy: already running — leaving it."
      return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
      echo "python3 not found on PATH — cannot start proxy." >&2
      return 1
    fi
    VM_PROXY_PORT="$port" VM_PROXY_HOST="${VM_PROXY_HOST:-0.0.0.0}" \
      nohup python3 "$proxy" >"$logf" 2>&1 &
    echo $! >"$pidf"
    sleep 1
    if [[ -n "$(_vm_proxy_listen_line)" ]]; then
      echo "proxy: started (pid $(cat "$pidf")), log: $logf"
    else
      echo "proxy: failed to start — see $logf" >&2
      cat "$logf" >&2
      return 1
    fi
  }

  # --- Scenario B: L3 VPN-share via IP forwarding + pf NAT ---------------

  # The interface that currently routes to the VPC — i.e. the live VPN tunnel.
  # Returns empty (or a non-utun iface) when the VPN is down.
  _vm_vpn_iface() { route -n get "${vpc_cidr%%/*}" 2>/dev/null | awk '/interface:/{print $2}'; }

  # The host's real uplink — where the VM's public traffic must NAT out to.
  _vm_uplink_iface() { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }

  _vm_vpn_share() {
    local iface; iface=$(_vm_vpn_iface)
    if [[ -z "$iface" || "$iface" != utun* ]]; then
      echo "✗ no VPN route to $vpc_cidr (route iface: '${iface:-none}')." >&2
      echo "  Connect the corp VPN on the Mac host, then rerun: vm_network_fix vpn" >&2
      return 1
    fi
    local uplink; uplink=$(_vm_uplink_iface)
    if [[ -z "$uplink" || "$uplink" == utun* ]]; then
      echo "✗ no non-VPN uplink (default route iface: '${uplink:-none}')." >&2
      echo "  Host is full-tunnel; VM cannot reach the public internet. Use a" >&2
      echo "  split-tunnel VPN profile, then rerun: vm_network_fix vpn" >&2
      return 1
    fi
    echo "VPN tunnel to $vpc_cidr : $iface   |   public uplink : $uplink"
    echo "Applying split NAT for $vm_subnet via anchor '$anchor' (needs sudo)…"
    sudo sysctl -w net.inet.ip.forwarding=1 >/dev/null || return 1
    # Reference our nat-anchor from the main ruleset, inserted right after the
    # com.apple nat-anchor so pf's section order (translation before filtering)
    # stays valid. Reloads /etc/pf.conf verbatim otherwise — no system rules lost.
    if ! awk '{print} /^nat-anchor "com\.apple/{print "nat-anchor \"'"$anchor"'\""}' \
         /etc/pf.conf | sudo pfctl -f - 2>/dev/null; then
      echo "✗ failed to load pf ruleset with anchor reference." >&2; return 1
    fi
    # Split NAT (pf is first-match): VPC-bound traffic out the VPN tunnel, all
    # other destinations out the real uplink. A single `to any -> (utun)` rule
    # black-holes public traffic on a split-tunnel VPN (only VPC routes exist in
    # the tunnel), which breaks e.g. CloudFront downloads from the VM.
    printf 'nat on %s from %s to %s -> (%s)\nnat on %s from %s to any -> (%s)\n' \
      "$iface" "$vm_subnet" "$vpc_cidr" "$iface" \
      "$uplink" "$vm_subnet" "$uplink" \
      | sudo pfctl -a "$anchor" -f - 2>/dev/null
    sudo pfctl -e 2>/dev/null   # no-op / nonzero if already enabled — fine
    echo "✓ NAT active. From the VM you now get BOTH:"
    echo "    VPC : curl -sv --max-time 8 https://<your-dev-host>/   (via $iface)"
    echo "    web : curl -sI --max-time 8 https://github.com         (via $uplink)"
    echo "  Non-persistent — rerun after reboot / VPN reconnect / utun change."
  }

  _vm_vpn_status() {
    local iface; iface=$(_vm_vpn_iface)
    echo "ip.forwarding : $(sysctl -n net.inet.ip.forwarding 2>/dev/null)"
    echo "VPN iface     : ${iface:-none} (route to $vpc_cidr)"
    echo "NAT rule ($anchor):"
    local rule; rule=$(sudo pfctl -a "$anchor" -s nat 2>/dev/null)
    if [[ -n "$rule" ]]; then print -r -- "$rule" | sed 's/^/  /'; else echo "  (none)"; fi
  }

  _vm_vpn_stop() {
    echo "Flushing NAT anchor '$anchor' + disabling forwarding (needs sudo)…"
    sudo pfctl -a "$anchor" -F nat 2>/dev/null
    sudo pfctl -f /etc/pf.conf 2>/dev/null   # drop the nat-anchor reference
    sudo sysctl -w net.inet.ip.forwarding=0 >/dev/null
    echo "✓ teardown done."
  }

  local cmd="${1:-fix}"
  case "$cmd" in
    status) _vm_status ;;
    stop)   _vm_stop ;;
    diag)   _vm_diag ;;
    vpn|vpn-share)        _vm_vpn_share ;;
    vpn-status)           _vm_vpn_status ;;
    vpn-stop|vpn-unshare) _vm_vpn_stop ;;
    fix|"")
      _vm_start || return 1
      echo
      _vm_diag
      echo
      echo "On the VM, wire HTTPS through the proxy:"
      echo "  PowerShell:  \$env:HTTPS_PROXY = \"http://$gateway:$port\""
      echo "  pip:         pip install --proxy http://$gateway:$port <pkg>"
      echo "  ps-agent:    [env] upstream_proxy=http://$gateway:$port  in config.toml"
      ;;
    *)
      echo "usage: vm_network_fix [fix|status|stop|diag|vpn|vpn-status|vpn-stop]" >&2
      return 2
      ;;
  esac
}
