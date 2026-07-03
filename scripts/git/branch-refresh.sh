# Git branch refresh helpers - sourced by init.zsh

gmain() {
  local base="${1:-main}"

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "gmain: not inside a git repository" >&2
    return 1
  }

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "gmain: working tree has uncommitted changes; stash or commit first" >&2
    return 1
  fi

  git checkout "$base" &&
    git pull --ff-only
}

gnew() {
  local branch="${1:-}"
  local base="${2:-main}"

  if [[ -z "$branch" || "$branch" == "-h" || "$branch" == "--help" ]]; then
    cat <<'EOF'
usage:
  gnew <branch> [base]

Refresh base branch, then create a new branch from it.
Defaults to base "main".

examples:
  gnew my-feature
  gnew fix/login develop
EOF
    return $([[ -n "$branch" ]] && echo 0 || echo 2)
  fi

  gmain "$base" &&
    git checkout -b "$branch"
}
