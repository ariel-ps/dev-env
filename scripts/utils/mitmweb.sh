# mitmweb — launch mitmproxy's web UI for interactive traffic inspection.
#
# Chrome (or any client) points at the listen port; the web UI runs separately
# and lets you browse/search/replay flows live in the browser.
#
#   Chrome -> mitmweb (records + web UI) -> [PS proxy] -> internet
#
#   mw-start                      # listen 8080, web UI 8081, upstream PS 3636
#   mw-start 8080 none            # direct (no upstream proxy, bypasses PS)
#   mw-start 8080 3636 8090       # explicit listen / upstream / web port
#   mw-stop                       # stop mitmweb, flush the flows file
#
# HTTPS interception needs the mitmproxy CA trusted by the client profile
# (already configured on this machine). --ssl-insecure lets mitmweb accept the
# upstream PS proxy's own intercepting cert.

MITMWEB_CAPTURE_DIR="${MITMWEB_CAPTURE_DIR:-$HOME/proxy-captures}"

mw-start() {
  local port="${1:-8080}"          # port mitmweb listens on (client points here)
  local upstream="${2:-3636}"      # existing PS proxy port, or "none" for direct
  local webport="${3:-8081}"       # port the web UI serves on

  mkdir -p "$MITMWEB_CAPTURE_DIR"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local flows="$MITMWEB_CAPTURE_DIR/mitmweb-${stamp}.flows"
  local pidfile="$MITMWEB_CAPTURE_DIR/mitmweb.pid"
  local logfile="$MITMWEB_CAPTURE_DIR/mitmweb-${stamp}.log"

  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    echo "mitmweb already running (pid $(cat "$pidfile")). Run mw-stop first." >&2
    return 1
  fi

  # Auto-advance to a free listen port if the requested one is taken.
  # Use netstat (not lsof) so listeners owned by other users are seen too.
  local tries=0
  while netstat -an -p tcp | grep -qE "[.*]\.${port}\b.*LISTEN"; do
    port=$((port + 1))
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      echo "No free port found near ${1:-8080}" >&2; return 1
    fi
  done

  # Build the proxy mode: regular (direct) or upstream (chain to PS proxy).
  local -a mode_args
  if [ "$upstream" = "none" ] || [ -z "$upstream" ]; then
    mode_args=(--mode "regular@${port}")
  else
    mode_args=(--mode "upstream:http://127.0.0.1:${upstream}@${port}" --ssl-insecure)
  fi

  # -w streams raw flows continuously so nothing is lost if the UI reloads.
  mitmweb \
    --listen-host 127.0.0.1 \
    "${mode_args[@]}" \
    --web-host 127.0.0.1 \
    --web-port "$webport" \
    --no-web-open-browser \
    -w "$flows" \
    >"$logfile" 2>&1 &
  local mpid=$!
  echo "$mpid" > "$pidfile"

  sleep 1
  if ! kill -0 "$mpid" 2>/dev/null; then
    echo "mitmweb failed to start. See $logfile" >&2
    rm -f "$pidfile"
    return 1
  fi

  echo "mitmweb proxy on http://127.0.0.1:${port} (pid $mpid)"
  echo "  web UI -> http://127.0.0.1:${webport}"
  [ "$upstream" != "none" ] && [ -n "$upstream" ] && \
    echo "  upstream -> PS proxy 127.0.0.1:${upstream}"
  echo "  flows  -> $flows"
  echo "$flows" > "$MITMWEB_CAPTURE_DIR/last-flows.path"
}

# Stop the running mitmweb; the flows file is flushed on its shutdown.
mw-stop() {
  local pidfile="$MITMWEB_CAPTURE_DIR/mitmweb.pid"
  if [ ! -f "$pidfile" ]; then
    echo "No mitmweb pidfile at $pidfile" >&2
    return 1
  fi
  local mpid; mpid="$(cat "$pidfile")"
  if kill -0 "$mpid" 2>/dev/null; then
    kill "$mpid" 2>/dev/null    # SIGTERM -> mitmproxy runs shutdown hooks, flushes flows
    echo "Stopped mitmweb (pid $mpid)"
  else
    echo "mitmweb (pid $mpid) not running" >&2
  fi
  rm -f "$pidfile"
  [ -f "$MITMWEB_CAPTURE_DIR/last-flows.path" ] && \
    echo "flows: $(cat "$MITMWEB_CAPTURE_DIR/last-flows.path")"
}
