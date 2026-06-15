# hermes-webui — run the Hermes WebUI (https://github.com/nesquena/hermes-webui)
# in Docker via `docker compose`.
#
# Usage:
#   hermes-webui [start]    clone/update repo, build, start in background
#   hermes-webui stop       stop & remove the container
#   hermes-webui restart    stop then start
#   hermes-webui logs       follow container logs (Ctrl-C to detach)
#   hermes-webui status     show container state
#   hermes-webui update     git pull + rebuild + restart
#   hermes-webui open       open the UI in the browser
#
# Serves on http://localhost:8787 (localhost only).
# Clones into $XDG_DATA_HOME/hermes-webui (default ~/.local/share/hermes-webui).
# Override the clone location with HERMES_WEBUI_DIR.
hermes-webui() {
  local repo_url="https://github.com/nesquena/hermes-webui.git"
  local repo_dir="${HERMES_WEBUI_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/hermes-webui}"
  local url="http://localhost:8787"

  # --- guards ---
  _hw_need_docker() {
    command -v docker >/dev/null 2>&1 || { echo "[hermes-webui] docker not found on PATH" >&2; return 1; }
    docker info >/dev/null 2>&1 || { echo "[hermes-webui] Docker daemon not running — start Docker Desktop" >&2; return 1; }
  }
  _hw_ensure_repo() {
    [ -d "$repo_dir/.git" ] && return 0
    echo "[hermes-webui] cloning $repo_url -> $repo_dir"
    mkdir -p "$(dirname "$repo_dir")" || return 1
    git clone "$repo_url" "$repo_dir"
  }
  # The compose file mounts HERMES_HOME (~/.hermes) and HERMES_WORKSPACE
  # (~/workspace) and reads UID/GID from .env. We pin all four as absolute
  # paths so the bind mounts resolve correctly no matter what environment
  # `docker compose` is invoked from (the compose ${HOME} default is fragile).
  # On macOS UID/GID are 501/20, not the Linux default 1000 — without these
  # the container can't read the mounted files.
  # Respects pre-set HERMES_HOME / HERMES_WORKSPACE if you override them.
  _hw_ensure_env() {
    local hermes_home="${HERMES_HOME:-$HOME/.hermes}"
    local workspace="${HERMES_WORKSPACE:-$HOME/workspace}"
    mkdir -p "$hermes_home" "$workspace"
    {
      printf 'UID=%s\nGID=%s\n' "$(id -u)" "$(id -g)"
      printf 'HERMES_HOME=%s\n' "$hermes_home"
      printf 'HERMES_WORKSPACE=%s\n' "$workspace"
    } > "$repo_dir/.env"
  }
  _hw_compose() { ( cd "$repo_dir" && docker compose "$@" ); }

  case "${1:-start}" in
    start)
      _hw_need_docker || return 1
      _hw_ensure_repo || return 1
      _hw_ensure_env  || return 1
      echo "[hermes-webui] building & starting..."
      _hw_compose up -d --build || return 1
      echo "[hermes-webui] up → $url   (logs: hermes-webui logs | stop: hermes-webui stop)"
      ;;
    stop)
      _hw_need_docker || return 1
      [ -d "$repo_dir/.git" ] || { echo "[hermes-webui] repo not found at $repo_dir" >&2; return 1; }
      _hw_compose down
      ;;
    restart)
      hermes-webui stop; hermes-webui start
      ;;
    logs)
      _hw_need_docker || return 1
      _hw_compose logs -f
      ;;
    status)
      _hw_need_docker || return 1
      _hw_compose ps
      ;;
    update)
      _hw_need_docker || return 1
      _hw_ensure_repo || return 1
      ( cd "$repo_dir" && git pull --ff-only ) || return 1
      _hw_ensure_env || return 1
      _hw_compose up -d --build && echo "[hermes-webui] updated → $url"
      ;;
    open)
      open "$url"
      ;;
    -h|--help|help)
      echo "usage: hermes-webui {start|stop|restart|logs|status|update|open}"
      ;;
    *)
      echo "[hermes-webui] unknown command '$1' (try: start stop restart logs status update open)" >&2
      return 1
      ;;
  esac
}
_hermes_webui() { compadd start stop restart logs status update open help }
compdef _hermes_webui hermes-webui
