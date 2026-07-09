# Project navigation helpers - sourced by init.zsh

_goto_project() {
  local path="$1"

  if [[ ! -d "$path" ]]; then
    echo "goto: directory not found: $path" >&2
    return 1
  fi

  cd "$path"
}

goto_ps-agent() {
  _goto_project "$HOME/Documents/projects/ps-agent"
}

goto_ps-platform() {
  _goto_project "$HOME/Documents/projects/ps-platform"
}

goto_dev-env() {
  _goto_project "$HOME/Documents/projects/dev-env"
}

goto_browser_extension() {
  _goto_project "$HOME/Documents/projects/browser_extension"
}
