#!/usr/bin/env bash
set -euo pipefail

# Bail if being sourced (e.g. by dev-env init.zsh which globs scripts/*/*.sh)
[[ -n "${ZSH_EVAL_CONTEXT:-}" && "$ZSH_EVAL_CONTEXT" == *:file* ]] && return 0

CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
DEFAULT_PORT=9222
DEFAULT_DATA_DIR="/tmp/chrome-cdp-profile"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [URL]

Launch Chrome with CDP (remote debugging) enabled.

Options:
  -p, --port PORT       Remote debugging port (default: $DEFAULT_PORT)
  -d, --data-dir DIR    User data directory (default: $DEFAULT_DATA_DIR)
  --headless            Run in headless mode
  --check               Check if CDP is already running on PORT
  -h, --help            Show this help

Examples:
  $(basename "$0")
  $(basename "$0") https://example.com
  $(basename "$0") -p 9223 --headless
  $(basename "$0") --check
EOF
}

PORT="$DEFAULT_PORT"
DATA_DIR="$DEFAULT_DATA_DIR"
HEADLESS=false
CHECK=false
URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)    PORT="$2"; shift 2 ;;
    -d|--data-dir) DATA_DIR="$2"; shift 2 ;;
    --headless)   HEADLESS=true; shift ;;
    --check)      CHECK=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    http*|file*)  URL="$1"; shift ;;
    *)            echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if "$CHECK"; then
  if curl -sf "http://localhost:${PORT}/json/version" >/dev/null 2>&1; then
    echo "CDP active on port $PORT"
    curl -s "http://localhost:${PORT}/json/version" | python3 -m json.tool
    exit 0
  else
    echo "No CDP session on port $PORT"
    exit 1
  fi
fi

if curl -sf "http://localhost:${PORT}/json/version" >/dev/null 2>&1; then
  echo "Chrome CDP already running on port $PORT"
  if [[ -n "$URL" ]]; then
    echo "Navigating to $URL via AppleScript..."
    osascript -e "tell application \"Google Chrome\" to set URL of active tab of front window to \"$URL\""
  fi
  exit 0
fi

ARGS=(
  "--remote-debugging-port=${PORT}"
  "--remote-allow-origins=*"
  "--no-first-run"
  "--no-default-browser-check"
  "--user-data-dir=${DATA_DIR}"
)

if "$HEADLESS"; then
  ARGS+=("--headless=new" "--disable-gpu")
fi

[[ -n "$URL" ]] && ARGS+=("$URL")

echo "Starting Chrome with CDP on port $PORT..."
echo "Data dir: $DATA_DIR"
[[ -n "$URL" ]] && echo "URL: $URL"

"$CHROME_BIN" "${ARGS[@]}" &
CHROME_PID=$!

# Wait for CDP to be ready
for i in $(seq 1 20); do
  if curl -sf "http://localhost:${PORT}/json/version" >/dev/null 2>&1; then
    echo "CDP ready — http://localhost:${PORT}"
    echo "Chrome PID: $CHROME_PID"
    exit 0
  fi
  sleep 0.5
done

echo "Timeout waiting for CDP on port $PORT" >&2
exit 1
