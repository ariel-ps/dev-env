# mitm-debug — run a standalone ps-agent proxy from a synced local checkout,
# purely for full-traffic capture. Independent of the real installed/signed
# agent: own port, own config, own output file, so it can run alongside it.
#
#   mitm-debug-run [port]          # the only command you need day to day:
#                                   # syncs, starts, trusts a fresh CA if
#                                   # needed (sudo prompt in THIS terminal),
#                                   # self-tests, enables the system proxy
#                                   # only if that self-test succeeds
#   mitm-debug-stop                # stop it AND always disable the system proxy
#
#   mitm-debug-sync                # (rarely needed directly - run does this)
#   mitm-debug-proxy-on / -off     # (rarely needed directly - run/stop do this)
#
# $PS_MITM_DEBUG_BRANCH (default: debug-traffic) is meant to be YOUR OWN
# personal/local-only branch on the ps-agent repo (never a PR branch) - set
# it in your shell profile to whatever you call yours. mitm-debug-run always
# pulls the latest commit on it before starting, so just push more commits
# to update it.
#
# Capture goes to $PS_MITM_DEBUG_CACHE/mitm_capture.jsonl. View it with:
#   mitm-watch.py "$PS_MITM_DEBUG_CACHE/mitm_capture.jsonl"
#
# System-wide proxy is risky: if this process dies while the system proxy
# still points at its port, EVERYTHING on the Mac loses internet, not just
# whatever you're debugging - not a hypothetical, it happened. So
# mitm-debug-run only flips the system proxy on after a real self-test
# request succeeds through it, and mitm-debug-stop ALWAYS flips it back off
# unconditionally, even if it thinks it wasn't the one that set it.

PS_MITM_DEBUG_CACHE="${PS_MITM_DEBUG_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/dev-env-ps-agent}"
PS_MITM_DEBUG_NETWORK_SERVICE="${PS_MITM_DEBUG_NETWORK_SERVICE:-Wi-Fi}"
PS_MITM_DEBUG_BRANCH="${PS_MITM_DEBUG_BRANCH:-debug-traffic}"
_PS_MITM_DEBUG_REPO="${PS_MITM_DEBUG_REPO:-git@github.com:prompt-security/ps-agent.git}"
_PS_MITM_DEBUG_CHECKOUT="$PS_MITM_DEBUG_CACHE/ps-agent-${PS_MITM_DEBUG_BRANCH}"

mitm-debug-proxy-on() {
  local port="$1"
  if [ -z "$port" ]; then
    echo "mitm-debug-proxy-on: usage: mitm-debug-proxy-on <port>" >&2
    return 1
  fi
  sudo networksetup -setsecurewebproxy "$PS_MITM_DEBUG_NETWORK_SERVICE" 127.0.0.1 "$port" \
    && sudo networksetup -setwebproxy "$PS_MITM_DEBUG_NETWORK_SERVICE" 127.0.0.1 "$port" \
    && echo "mitm-debug: system proxy (${PS_MITM_DEBUG_NETWORK_SERVICE}) -> 127.0.0.1:${port}"
}

mitm-debug-proxy-off() {
  sudo networksetup -setsecurewebproxystate "$PS_MITM_DEBUG_NETWORK_SERVICE" off
  sudo networksetup -setwebproxystate "$PS_MITM_DEBUG_NETWORK_SERVICE" off
  echo "mitm-debug: system proxy (${PS_MITM_DEBUG_NETWORK_SERVICE}) disabled"
}

# Resolve a python with mitmproxy installed explicitly, rather than trusting
# whatever bare `python3` resolves to - a project-local .venv (e.g. one
# auto-activated by direnv when cd'd into the real ps-agent repo) can shadow
# it even inside this function's own subshell, silently running against a
# DIFFERENT mitmproxy install than the one this was tested against. That
# mismatch was the exact cause of a "certstore stays None, every TLS
# connection fails" bug that looked identical to a real code bug.
_mitm_debug_python() {
  local candidate
  for candidate in "${PS_MITM_DEBUG_PYTHON:-}" "$HOME/miniconda3/bin/python3" "$(command -v python3)"; do
    [ -n "$candidate" ] || continue
    "$candidate" -c "import mitmproxy" >/dev/null 2>&1 && { echo "$candidate"; return 0; }
  done
  echo "mitm-debug: no python with mitmproxy installed found (tried \$PS_MITM_DEBUG_PYTHON, ~/miniconda3/bin/python3, \$(command -v python3))" >&2
  return 1
}

mitm-debug-sync() {
  mkdir -p "$PS_MITM_DEBUG_CACHE"
  if [ -d "$_PS_MITM_DEBUG_CHECKOUT/.git" ]; then
    echo "mitm-debug-sync: pulling ${PS_MITM_DEBUG_BRANCH} ..."
    (cd "$_PS_MITM_DEBUG_CHECKOUT" && git fetch origin "$PS_MITM_DEBUG_BRANCH" \
      && git checkout -q "$PS_MITM_DEBUG_BRANCH" && git reset --hard "origin/$PS_MITM_DEBUG_BRANCH")
  else
    echo "mitm-debug-sync: cloning ${PS_MITM_DEBUG_BRANCH} ..."
    git clone --branch "$PS_MITM_DEBUG_BRANCH" --single-branch "$_PS_MITM_DEBUG_REPO" "$_PS_MITM_DEBUG_CHECKOUT"
  fi
}

# Write a small dev config.toml (own port, log_dev_debug always on, local
# scanners off) the first time, reusing domain/api_key from the real
# installed config so the heartbeat/policy fetch still authenticates.
_mitm_debug_ensure_config() {
  local cfg="$PS_MITM_DEBUG_CACHE/config.toml"
  local port="$1"
  # Always rewrite (not just on first run) so the port always matches this
  # run's auto-selected free port - a stale config from an earlier port
  # would silently make the proxy listen on the wrong port.

  local real_cfg="/Library/Application Support/Prompt/config.toml"
  local content
  content="$(cat "$real_cfg" 2>/dev/null)" || content="$(sudo cat "$real_cfg" 2>/dev/null)"
  local domain api_key
  domain="$(printf '%s\n' "$content" | awk -F'=' '/^\[app\]/{f=1;next} /^\[/{f=0} f && $1=="domain"{print $2; exit}')"
  api_key="$(printf '%s\n' "$content" | awk -F'=' '/^\[app\]/{f=1;next} /^\[/{f=0} f && $1=="api_key"{print $2; exit}')"

  cat > "$cfg" <<EOF
[app]
domain=$domain
api_key=$api_key

[modules]
local_secrets=false
local_sensitive_data=false
cache=true

[env]
port=$port
upstream_proxy=
ssl_verify=false
follow_redirects=true
user_email=

[settings]
proto_scan_chunk_size=40

[logger]
log_modified_payloads=false
log_dev_debug=true
EOF
  echo "mitm-debug: wrote dev config -> $cfg (port=$port)"
}

mitm-debug-run() {
  local port="${1:-38080}"

  mitm-debug-sync

  local pidfile="$PS_MITM_DEBUG_CACHE/mitm-debug.pid"
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "mitm-debug-run: already running (pid $(cat "$pidfile")). Run mitm-debug-stop first." >&2
    return 1
  fi

  # Auto-advance to a free port if the requested one is taken - use netstat
  # (not lsof), which sees listeners owned by other users/sandboxes too.
  local tries=0
  while netstat -an -p tcp | grep -qE "[.*]\.${port}\b.*LISTEN"; do
    port=$((port + 1))
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      echo "mitm-debug-run: no free port found near ${1:-38080}" >&2; return 1
    fi
  done

  local pybin
  pybin="$(_mitm_debug_python)" || return 1

  _mitm_debug_ensure_config "$port"

  local logfile="$PS_MITM_DEBUG_CACHE/mitm-debug.log"
  local capture="$PS_MITM_DEBUG_CACHE/mitm_capture.jsonl"
  local certdir="$PS_MITM_DEBUG_CACHE/.certs"
  local cert_is_new=0
  [ -f "$certdir/mitmproxy-ca-cert.pem" ] || cert_is_new=1

  ( cd "$_PS_MITM_DEBUG_CHECKOUT" \
    && PS_CONFIG_FILE_PATH="$PS_MITM_DEBUG_CACHE/config.toml" \
       PS_MITM_CAPTURE_PATH="$capture" \
       PS_PROXY_CERT_DIR="$certdir" \
       "$pybin" debug_traffic_run.py \
  ) >"$logfile" 2>&1 &
  local mpid=$!
  echo "$mpid" > "$pidfile"

  sleep 1
  if ! kill -0 "$mpid" 2>/dev/null; then
    echo "mitm-debug-run: failed to start. See $logfile" >&2
    rm -f "$pidfile"
    return 1
  fi

  # The dev instance runs as your regular user, not root, so it can't share
  # the real agent's root-owned cert dir - it generates its own CA here on
  # first run, which needs trusting once before TLS interception will work.
  # Trust it right here (sudo prompts in THIS terminal, not through any
  # background/sandboxed process) instead of printing a command to copy-paste
  # and re-run separately.
  if [ "$cert_is_new" = 1 ]; then
    sleep 1
    if [ -f "$certdir/mitmproxy-ca-cert.pem" ]; then
      echo "mitm-debug: trusting freshly generated dev CA (sudo needed) ..."
      sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$certdir/mitmproxy-ca-cert.pem"
    fi
  fi

  echo "mitm-debug proxy on 127.0.0.1:${port} (pid $mpid)"
  echo "  python  -> $pybin"
  echo "  capture -> $capture"

  # Self-test through the real system trust store (no --cacert override) -
  # this is exactly what a real client app will see. Only flip the system
  # proxy on if it actually succeeds, so a broken/untrusted proxy never gets
  # a chance to take down the whole Mac's internet.
  if curl -x "http://127.0.0.1:${port}" -sS -o /dev/null -m 5 -w "" https://www.google.com/ 2>/dev/null; then
    mitm-debug-proxy-on "$port"
    echo "  view with: mitm-watch.py \"$capture\""
    echo "  when done: mitm-debug-stop  (also disables the system proxy)"
  else
    echo "mitm-debug: self-test through the proxy failed - NOT enabling the system proxy." >&2
    echo "  Check $logfile, or trust the CA if this is a fresh cert dir, then re-run." >&2
  fi
}

mitm-debug-stop() {
  local pidfile="$PS_MITM_DEBUG_CACHE/mitm-debug.pid"
  if [ -f "$pidfile" ]; then
    local mpid; mpid="$(cat "$pidfile")"
    if kill -0 "$mpid" 2>/dev/null; then
      kill "$mpid" 2>/dev/null
      echo "Stopped mitm-debug (pid $mpid)"
    else
      echo "mitm-debug (pid $mpid) not running" >&2
    fi
    rm -f "$pidfile"
  else
    echo "mitm-debug-stop: no pidfile (process may still be running elsewhere)" >&2
  fi
  # Unconditional: never leave the system proxy pointed at a port nothing is
  # listening on, regardless of whether this call thought anything was running.
  mitm-debug-proxy-off
}
