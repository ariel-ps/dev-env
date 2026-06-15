# openspec-ui — run the OpenSpec UI dashboard (https://github.com/ToruAI/openspec-ui)
# in Docker, pointed at a project's openspec/ directory.
#
# Usage:
#   openspec-ui [start] [project-dir]   build (if needed) & start, watching project-dir
#                                       (project-dir defaults to the current directory)
#   openspec-ui stop                    stop & remove the container
#   openspec-ui restart [project-dir]   stop then start
#   openspec-ui logs                    follow container logs (Ctrl-C to detach)
#   openspec-ui status                  show container state
#   openspec-ui build                   clone/pull repo & (re)build the image
#   openspec-ui open                    open the UI in the browser
#
# Serves on http://localhost:3000 (override with OPENSPEC_UI_PORT).
# Clones into $XDG_DATA_HOME/openspec-ui (default ~/.local/share/openspec-ui).
# Override the clone location with OPENSPEC_UI_DIR.
openspec-ui() {
  local repo_url="https://github.com/ToruAI/openspec-ui.git"
  local repo_dir="${OPENSPEC_UI_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/openspec-ui}"
  local image="openspec-ui"
  local container="openspec-ui"
  local port="${OPENSPEC_UI_PORT:-3000}"
  local config_dir="$HOME/.config/openspec-ui"
  local config_file="$config_dir/openspec-ui.json"
  local url="http://localhost:$port"

  # --- guards & helpers ---
  _osu_need_docker() {
    command -v docker >/dev/null 2>&1 || { echo "[openspec-ui] docker not found on PATH" >&2; return 1; }
    docker info >/dev/null 2>&1 || { echo "[openspec-ui] Docker daemon not running — start Docker Desktop" >&2; return 1; }
  }
  _osu_ensure_repo() {
    [ -d "$repo_dir/.git" ] && return 0
    echo "[openspec-ui] cloning $repo_url -> $repo_dir"
    mkdir -p "$(dirname "$repo_dir")" || return 1
    git clone "$repo_url" "$repo_dir"
  }
  _osu_ensure_image() {
    docker image inspect "$image" >/dev/null 2>&1 && return 0
    _osu_ensure_repo || return 1
    echo "[openspec-ui] building image '$image' (first run)..."
    docker build -t "$image" "$repo_dir"
  }
  # Write a config that maps the mounted project to its openspec/ dir. The repo
  # root is bind-mounted at /repos inside the container, so the source path is
  # /repos/openspec regardless of where the project lives on the host.
  _osu_write_config() {
    local name="$1"
    mkdir -p "$config_dir" || return 1
    cat > "$config_file" <<JSON
{
  "sources": [
    { "name": "$name", "path": "/repos/openspec" }
  ],
  "port": 3000
}
JSON
  }

  case "${1:-start}" in
    start)
      _osu_need_docker || return 1
      local proj="${2:-$PWD}"
      proj="${proj:A}"                                  # absolute, resolved
      [ -d "$proj" ] || { echo "[openspec-ui] no such directory: $proj" >&2; return 1; }
      if [ ! -d "$proj/openspec" ]; then
        echo "[openspec-ui] warning: '$proj' has no openspec/ dir — the dashboard will be empty until one exists" >&2
      fi
      _osu_ensure_image || return 1
      _osu_write_config "${proj:t}" || return 1
      docker rm -f "$container" >/dev/null 2>&1        # clear any stale container
      echo "[openspec-ui] starting on '$proj'..."
      docker run -d --name "$container" \
        -p "$port:3000" \
        -v "$proj:/repos" \
        -v "$config_file:/app/openspec-ui.json" \
        "$image" >/dev/null || return 1
      echo "[openspec-ui] up → $url   (logs: openspec-ui logs | stop: openspec-ui stop)"
      ;;
    stop)
      _osu_need_docker || return 1
      docker rm -f "$container" >/dev/null 2>&1 && echo "[openspec-ui] stopped" || echo "[openspec-ui] not running"
      ;;
    restart)
      openspec-ui stop; openspec-ui start "$2"
      ;;
    logs)
      _osu_need_docker || return 1
      docker logs -f "$container"
      ;;
    status)
      _osu_need_docker || return 1
      docker ps -a --filter "name=^/${container}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
      ;;
    build)
      _osu_need_docker || return 1
      _osu_ensure_repo || return 1
      ( cd "$repo_dir" && git pull --ff-only ) || return 1
      echo "[openspec-ui] building image '$image'..."
      docker build -t "$image" "$repo_dir" && echo "[openspec-ui] image built — run: openspec-ui start"
      ;;
    open)
      open "$url"
      ;;
    -h|--help|help)
      echo "usage: openspec-ui {start [dir]|stop|restart [dir]|logs|status|build|open}"
      ;;
    *)
      echo "[openspec-ui] unknown command '$1' (try: start stop restart logs status build open)" >&2
      return 1
      ;;
  esac
}
_openspec_ui() { compadd start stop restart logs status build open help }
compdef _openspec_ui openspec-ui
