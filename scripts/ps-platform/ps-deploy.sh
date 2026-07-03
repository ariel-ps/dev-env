# ps-deploy — build ps-platform branch images and deploy to the ariel-ps ArgoCD dev env.
#
# Usage:
#   ps-deploy [options]
#
# Options:
#   -b, --branch BRANCH   Branch to build and deploy (default: current git branch in PS_PLATFORM_DIR)
#   -n, --no-build        Skip image build — just update values.yaml with the branch tag
#   -h, --help            Show help
#
# Env overrides:
#   PS_PLATFORM_DIR       Path to ps-platform repo   (default: ~/Documents/projects/ps-platform)
#   PS_ARGOCD_DIR         Path to ps-argocd-dev-envs (default: ~/Documents/projects/ps-argocd-dev-envs)
#   PS_ARGOCD_ENV         ArgoCD environment name    (default: ariel-ps)

ps-deploy() {
  local platform_dir="${PS_PLATFORM_DIR:-$HOME/Documents/projects/ps-platform}"
  local argocd_dir="${PS_ARGOCD_DIR:-$HOME/Documents/projects/ps-argocd-dev-envs}"
  local env_name="${PS_ARGOCD_ENV:-ariel-ps}"
  local branch="" do_build=1

  _psd_usage() {
    cat <<'EOF'
ps-deploy — build ps-platform branch images and deploy to ariel-ps ArgoCD dev env.

Usage:
  ps-deploy [options]

Options:
  -b, --branch BRANCH   Branch to build and deploy (default: current branch in ps-platform)
  -n, --no-build        Skip image build, just update values.yaml with the branch tag
  -h, --help            Show this help

Examples:
  ps-deploy                            # build current branch, deploy
  ps-deploy -b PROE-7016-my-feature    # build specific branch, deploy
  ps-deploy -n -b PROE-7016-my-feature # skip build, just update tag
EOF
  }

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--branch) branch="$2"; shift 2 ;;
      -n|--no-build) do_build=0; shift ;;
      -h|--help) _psd_usage; return 0 ;;
      *) echo "[ps-deploy] Unknown option: $1" >&2; _psd_usage; return 1 ;;
    esac
  done

  # Resolve branch
  if [[ -z "$branch" ]]; then
    branch=$(git -C "$platform_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
      echo "[ps-deploy] Could not determine branch from $platform_dir — use -b BRANCH" >&2
      return 1
    fi
  fi

  # Mirror the workflow's tag sanitizer: non-[alnum_] → '-'
  local tag
  tag=$(printf '%s' "$branch" | sed 's/[^[:alnum:]_]/-/g')
  echo "[ps-deploy] branch=$branch  tag=$tag  env=$env_name"

  # Build images
  if [[ $do_build -eq 1 ]]; then
    echo "[ps-deploy] Building images via ps-build-images..."
    ps-build-images --branch "$branch" || { echo "[ps-deploy] Image build failed" >&2; return 1; }
  else
    echo "[ps-deploy] Skipping image build (--no-build)"
  fi

  # Update values.yaml — replace all active imageTags (skip commented lines)
  local values="$argocd_dir/environments/$env_name/values.yaml"
  if [[ ! -f "$values" ]]; then
    echo "[ps-deploy] values.yaml not found: $values" >&2
    return 1
  fi

  echo "[ps-deploy] Updating image tags in $values..."
  # Only replace uncommented imageTag lines
  sed -i '' "s|^\([[:space:]]*imageTag:\) \".*\"|\1 \"$tag\"|" "$values"

  # Verify at least one tag was updated
  local updated
  updated=$(grep -c "imageTag: \"$tag\"" "$values" 2>/dev/null || true)
  if [[ "$updated" -eq 0 ]]; then
    echo "[ps-deploy] Warning: no imageTag lines updated in values.yaml" >&2
  else
    echo "[ps-deploy] Updated $updated imageTag entries → \"$tag\""
  fi

  # Commit and push
  echo "[ps-deploy] Committing and pushing to ps-argocd-dev-envs..."
  git -C "$argocd_dir" add "environments/$env_name/values.yaml"
  git -C "$argocd_dir" commit -m "deploy $env_name: $branch" || {
    echo "[ps-deploy] Nothing to commit (tag already set?)"
  }
  git -C "$argocd_dir" push || { echo "[ps-deploy] Push failed" >&2; return 1; }

  echo "[ps-deploy] Done — ArgoCD will pick up the change shortly."
  echo "[ps-deploy] https://argocd.dev.prompt.security/applications/$env_name"
}
