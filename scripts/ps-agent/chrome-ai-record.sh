# Record all Chrome traffic through mitmproxy while running Google AI mode.
#
# mitmdump listens on its own port and chains UPSTREAM to the existing PS proxy,
# so the chain is:  Chrome -> mitmdump (records) -> PS proxy -> internet.
# Every request/response is captured to a HAR file and a raw mitmproxy flow file.
#
#   chrome-ai-record                       # listen 3637, upstream PS 3636, US override
#   chrome-ai-record 3637 3636 intl        # explicit listen/upstream, no country override
#   chrome-ai-record 3637 none             # direct (no upstream proxy, bypasses PS)
#   chrome-ai-record-stop                  # stop mitmdump, finalize the HAR
#
# Requires the mitmproxy CA to be trusted by the Chrome profile for HTTPS
# interception (already configured on this machine). --ssl-insecure lets mitmdump
# accept the upstream PS proxy's own intercepting cert.

CHROME_AI_CAPTURE_DIR="${CHROME_AI_CAPTURE_DIR:-$HOME/proxy-captures}"

chrome-ai-record() {
  local port="${1:-7777}"          # port mitmdump listens on (Chrome points here)
  local upstream="${2:-3636}"      # existing PS proxy port, or "none" for direct
  local mode="${3:-us}"            # us | intl  (country override on/off)
  local proxy="http://127.0.0.1:${port}"

  mkdir -p "$CHROME_AI_CAPTURE_DIR"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local har="$CHROME_AI_CAPTURE_DIR/chrome-ai-${stamp}.har"
  local flows="$CHROME_AI_CAPTURE_DIR/chrome-ai-${stamp}.flows"
  local pidfile="$CHROME_AI_CAPTURE_DIR/mitmdump.pid"
  local logfile="$CHROME_AI_CAPTURE_DIR/mitmdump-${stamp}.log"

  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "mitmdump already running (pid $(cat "$pidfile")). Run chrome-ai-record-stop first." >&2
    return 1
  fi

  # Auto-advance to a free listen port if the requested one is taken.
  # Use netstat (not lsof) so listeners owned by other users are seen too.
  local tries=0
  while netstat -an -p tcp | grep -qE "[.*]\.${port}\b.*LISTEN"; do
    port=$((port + 1))
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      echo "No free port found near ${1:-7777}" >&2; return 1
    fi
  done
  proxy="http://127.0.0.1:${port}"

  # Build the proxy mode: regular (direct) or upstream (chain to PS proxy).
  local -a mode_args
  if [ "$upstream" = "none" ] || [ -z "$upstream" ]; then
    mode_args=(--mode "regular@${port}")
  else
    mode_args=(--mode "upstream:http://127.0.0.1:${upstream}@${port}" --ssl-insecure)
  fi

  # -w streams raw flows continuously; hardump writes the HAR on shutdown.
  mitmdump \
    --listen-host 127.0.0.1 \
    "${mode_args[@]}" \
    -w "$flows" \
    --set hardump="$har" \
    >"$logfile" 2>&1 &
  local mpid=$!
  echo "$mpid" > "$pidfile"

  sleep 1
  if ! kill -0 "$mpid" 2>/dev/null; then
    echo "mitmdump failed to start. See $logfile" >&2
    rm -f "$pidfile"
    return 1
  fi

  echo "mitmdump listening on $proxy (pid $mpid)"
  [ "$upstream" != "none" ] && [ -n "$upstream" ] && \
    echo "  upstream -> PS proxy 127.0.0.1:${upstream}"
  echo "  flows -> $flows"
  echo "  har   -> $har (written on stop)"
  echo "$har" > "$CHROME_AI_CAPTURE_DIR/last-har.path"

  if [ "$mode" = "intl" ]; then
    chrome-ai-intl "$proxy"
  else
    chrome-ai "$proxy"
  fi
}

# Stop the recording mitmdump; the HAR is flushed on its shutdown.
chrome-ai-record-stop() {
  local pidfile="$CHROME_AI_CAPTURE_DIR/mitmdump.pid"
  if [ ! -f "$pidfile" ]; then
    echo "No mitmdump pidfile at $pidfile" >&2
    return 1
  fi
  local mpid; mpid="$(cat "$pidfile")"
  if kill -0 "$mpid" 2>/dev/null; then
    kill "$mpid" 2>/dev/null    # SIGTERM -> mitmproxy runs shutdown hooks, flushes HAR
    echo "Stopped mitmdump (pid $mpid)"
  else
    echo "mitmdump (pid $mpid) not running" >&2
  fi
  rm -f "$pidfile"
  [ -f "$CHROME_AI_CAPTURE_DIR/last-har.path" ] && \
    echo "HAR: $(cat "$CHROME_AI_CAPTURE_DIR/last-har.path")"
}
