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
# Everything mitm-debug touches lives under $PS_MITM_DEBUG_CACHE:
#   config.toml           generated dev config (own port, real domain/api_key)
#   mitm-debug.pid/.log   the running process's pid and stdout+stderr
#   mitm_capture.jsonl    captured traffic, read by mitm-watch.py
#   .certs/               this instance's own (untrusted-by-default) dev CA
#   ps-agent-<branch>/    the synced checkout mitm-debug-run execs into
#
# System-wide proxy is risky: if this process dies while the system proxy
# still points at its port, EVERYTHING on the Mac loses internet, not just
# whatever you're debugging - not a hypothetical, it happened. So
# mitm-debug-run only flips the system proxy on after a real self-test
# request succeeds through it, and mitm-debug-stop ALWAYS flips it back off
# unconditionally, even if it thinks it wasn't the one that set it.

# --- user-tunable (env-overridable) ---
PS_MITM_DEBUG_CACHE="${PS_MITM_DEBUG_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/dev-env-ps-agent}"
PS_MITM_DEBUG_NETWORK_SERVICE="${PS_MITM_DEBUG_NETWORK_SERVICE:-Wi-Fi}"
PS_MITM_DEBUG_BRANCH="${PS_MITM_DEBUG_BRANCH:-debug-traffic}"
PS_MITM_DEBUG_DEFAULT_PORT="${PS_MITM_DEBUG_DEFAULT_PORT:-38080}"
_PS_MITM_DEBUG_REPO="${PS_MITM_DEBUG_REPO:-git@github.com:prompt-security/ps-agent.git}"

# --- fixed internals (not meant to be overridden) ---
_PS_MITM_DEBUG_ENTRYPOINT="debug_traffic_run.py"
_PS_MITM_DEBUG_CONDA_PYTHON="$HOME/miniconda3/bin/python3"
_PS_MITM_DEBUG_REAL_CONFIG="/Library/Application Support/Prompt/config.toml"
_PS_MITM_DEBUG_SELFTEST_URL="https://www.google.com/"
_PS_MITM_DEBUG_SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"
_PS_MITM_DEBUG_PORT_SCAN_TRIES=20

# --- derived paths - all state lives under one cache dir, defined once here
# so mitm-debug-run and mitm-debug-stop can never disagree about where a
# file is ---
_PS_MITM_DEBUG_CHECKOUT="$PS_MITM_DEBUG_CACHE/ps-agent-${PS_MITM_DEBUG_BRANCH}"
_PS_MITM_DEBUG_CONFIG="$PS_MITM_DEBUG_CACHE/config.toml"
_PS_MITM_DEBUG_PIDFILE="$PS_MITM_DEBUG_CACHE/mitm-debug.pid"
_PS_MITM_DEBUG_LOGFILE="$PS_MITM_DEBUG_CACHE/mitm-debug.log"
_PS_MITM_DEBUG_CAPTURE="$PS_MITM_DEBUG_CACHE/mitm_capture.jsonl"
_PS_MITM_DEBUG_CERTDIR="$PS_MITM_DEBUG_CACHE/.certs"
_PS_MITM_DEBUG_CA_CERT="$_PS_MITM_DEBUG_CERTDIR/mitmproxy-ca-cert.pem"

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
  for candidate in "${PS_MITM_DEBUG_PYTHON:-}" "$_PS_MITM_DEBUG_CONDA_PYTHON" "$(command -v python3)"; do
    [ -n "$candidate" ] || continue
    "$candidate" -c "import mitmproxy" >/dev/null 2>&1 && { echo "$candidate"; return 0; }
  done
  echo "mitm-debug: no python with mitmproxy installed found (tried \$PS_MITM_DEBUG_PYTHON, $_PS_MITM_DEBUG_CONDA_PYTHON, \$(command -v python3))" >&2
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
#
# Always rewrite (not just on first run) so the port always matches this
# run's auto-selected free port - a stale config from an earlier port would
# silently make the proxy listen on the wrong port.
_mitm_debug_ensure_config() {
  local port="$1"
  local cfg="$_PS_MITM_DEBUG_CONFIG"

  local content
  content="$(cat "$_PS_MITM_DEBUG_REAL_CONFIG" 2>/dev/null)" || content="$(sudo cat "$_PS_MITM_DEBUG_REAL_CONFIG" 2>/dev/null)"
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

# Auto-advance from the requested port to a free one - use netstat (not
# lsof), which sees listeners owned by other users/sandboxes too. Prints the
# free port on success; prints nothing and fails after
# $_PS_MITM_DEBUG_PORT_SCAN_TRIES tries.
_mitm_debug_free_port() {
  local port="$1" tries=0
  while netstat -an -p tcp | grep -qE "[.*]\.${port}\b.*LISTEN"; do
    port=$((port + 1))
    tries=$((tries + 1))
    if [ "$tries" -ge "$_PS_MITM_DEBUG_PORT_SCAN_TRIES" ]; then
      echo "mitm-debug-run: no free port found near $1" >&2
      return 1
    fi
  done
  echo "$port"
}

mitm-debug-run() {
  local requested_port="${1:-$PS_MITM_DEBUG_DEFAULT_PORT}"

  if [ -f "$_PS_MITM_DEBUG_PIDFILE" ]; then
    local running_pid; running_pid="$(cat "$_PS_MITM_DEBUG_PIDFILE")"
    if kill -0 "$running_pid" 2>/dev/null; then
      echo "mitm-debug-run: already running (pid $running_pid). Run mitm-debug-stop first." >&2
      return 1
    fi
  fi

  mitm-debug-sync

  local port
  port="$(_mitm_debug_free_port "$requested_port")" || return 1

  local pybin
  pybin="$(_mitm_debug_python)" || return 1

  _mitm_debug_ensure_config "$port"

  local cert_is_new=0
  [ -f "$_PS_MITM_DEBUG_CA_CERT" ] || cert_is_new=1

  ( cd "$_PS_MITM_DEBUG_CHECKOUT" \
    && PS_CONFIG_FILE_PATH="$_PS_MITM_DEBUG_CONFIG" \
       PS_MITM_CAPTURE_PATH="$_PS_MITM_DEBUG_CAPTURE" \
       PS_PROXY_CERT_DIR="$_PS_MITM_DEBUG_CERTDIR" \
       "$pybin" "$_PS_MITM_DEBUG_ENTRYPOINT" \
  ) >"$_PS_MITM_DEBUG_LOGFILE" 2>&1 &
  local mpid=$!
  echo "$mpid" > "$_PS_MITM_DEBUG_PIDFILE"

  sleep 1
  if ! kill -0 "$mpid" 2>/dev/null; then
    echo "mitm-debug-run: failed to start. See $_PS_MITM_DEBUG_LOGFILE" >&2
    rm -f "$_PS_MITM_DEBUG_PIDFILE"
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
    if [ -f "$_PS_MITM_DEBUG_CA_CERT" ]; then
      echo "mitm-debug: trusting freshly generated dev CA (sudo needed) ..."
      sudo security add-trusted-cert -d -r trustRoot -k "$_PS_MITM_DEBUG_SYSTEM_KEYCHAIN" "$_PS_MITM_DEBUG_CA_CERT"
    fi
  fi

  echo "mitm-debug proxy on 127.0.0.1:${port} (pid $mpid)"
  echo "  python  -> $pybin"
  echo "  capture -> $_PS_MITM_DEBUG_CAPTURE"

  # Self-test through the real system trust store (no --cacert override) -
  # this is exactly what a real client app will see. Only flip the system
  # proxy on if it actually succeeds, so a broken/untrusted proxy never gets
  # a chance to take down the whole Mac's internet.
  if curl -x "http://127.0.0.1:${port}" -sS -o /dev/null -m 5 -w "" "$_PS_MITM_DEBUG_SELFTEST_URL" 2>/dev/null; then
    mitm-debug-proxy-on "$port"
    echo "  view with: mitm-watch.py \"$_PS_MITM_DEBUG_CAPTURE\""
    echo "  when done: mitm-debug-stop  (also disables the system proxy)"
  else
    echo "mitm-debug: self-test through the proxy failed - NOT enabling the system proxy." >&2
    echo "  Check $_PS_MITM_DEBUG_LOGFILE, or trust the CA if this is a fresh cert dir, then re-run." >&2
  fi
}

mitm-debug-stop() {
  if [ -f "$_PS_MITM_DEBUG_PIDFILE" ]; then
    local mpid; mpid="$(cat "$_PS_MITM_DEBUG_PIDFILE")"
    if kill -0 "$mpid" 2>/dev/null; then
      kill "$mpid" 2>/dev/null
      echo "Stopped mitm-debug (pid $mpid)"
    else
      echo "mitm-debug (pid $mpid) not running" >&2
    fi
    rm -f "$_PS_MITM_DEBUG_PIDFILE"
  else
    echo "mitm-debug-stop: no pidfile (process may still be running elsewhere)" >&2
  fi
  # Unconditional: never leave the system proxy pointed at a port nothing is
  # listening on, regardless of whether this call thought anything was running.
  mitm-debug-proxy-off
}
