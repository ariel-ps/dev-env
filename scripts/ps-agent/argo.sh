# argo / AWS non-prod session helper
argo_env_start() {
  local profile="${1:-nonprod}"
  if aws sts get-caller-identity --profile "$profile" >/dev/null 2>&1; then
    echo "[argo_env_start] SSO session for '$profile' still valid"
  else
    echo "[argo_env_start] logging in to SSO for '$profile'..."
    aws sso login --profile "$profile" || return 1
  fi
  export AWS_PROFILE="$profile"
  echo "[argo_env_start] AWS_PROFILE=$AWS_PROFILE"
  aws sts get-caller-identity
}

argo_env_stop() {
  unset AWS_PROFILE
  echo "[argo_env_stop] AWS_PROFILE unset"
}

argo_npm_login() {
  local profile="${1:-nonprod}"
  argo_env_start "$profile" >/dev/null || return 1
  aws codeartifact login --tool npm --domain prompt-security \
    --repository npm-proxy --region eu-north-1 --profile "$profile"
}

argo_pip_login() {
  local profile="${1:-nonprod}"
  argo_env_start "$profile" >/dev/null || return 1
  aws codeartifact login --tool pip --domain prompt-security \
    --repository pypi-proxy --region eu-north-1 --profile "$profile"
}

# Dispatch the ps-argocd-dev-envs "Create Environment" workflow.
# usage: argo_create_env [ttl_hours] [prompt_version]
argo_create_env() {
  local ttl="${1:-8}"
  local prompt_version="${2:-}"
  gh workflow run create_env.yml \
    -R prompt-security/ps-argocd-dev-envs \
    --ref main \
    -f ttl_hours="$ttl" \
    -f instance_type=spot \
    -f gpu=false \
    -f prompt_version="$prompt_version" \
    -f icap=false \
    -f empty_env=false \
    -f additional_setup=false \
    -f shared_gpu=true \
    && echo "[argo_create_env] dispatched (ttl=${ttl}h)"
}

# Dispatch the ps-argocd-dev-envs "Delete Environment" workflow.
# usage: argo_delete_env [additional_setup=true|false]
argo_delete_env() {
  local additional="${1:-false}"
  gh workflow run delete_env.yml \
    -R prompt-security/ps-argocd-dev-envs \
    --ref main \
    -f additional_setup="$additional" \
    && echo "[argo_delete_env] dispatched (additional_setup=${additional})"
}

# Show recent ps-argocd-dev-envs runs triggered by the authenticated user.
# usage: argo_env_status [limit]
argo_env_status() {
  local limit="${1:-1}"
  local me; me=$(gh api user --jq .login) || return 1
  gh run list -R prompt-security/ps-argocd-dev-envs \
    --user="$me" --limit "$limit"
}

# Pin service image(s) in a dev-env branch's values.yaml, commit, and push.
# Pushing makes ArgoCD auto-sync the branch — i.e. this deploys.
#
# usage: argo_set <branch> <imageTag> <service[:imageName]> [service2[:imageName2] ...]
#   e.g. argo_set ariel-ps PROE-7092-HARDENING-DISABLE-WITH-ROTATION \
#            ps-backend ps-backend-protect:ps-backend
#
# - <branch> is also the env dir name (environments/<branch>/values.yaml).
# - <imageName> defaults to the service key; give svc:name when they differ
#   (e.g. ps-backend-protect runs the ps-backend image).
# - Registry defaults to ghcr.io/ps-prod/ (override: ARGO_SET_REGISTRY).
# - Repo path: PS_ARGOCD_REPO (default ~/Documents/projects/ps-argocd-dev-envs).
# - Set ARGO_SET_DRY=1 to edit + show the diff but NOT commit/push.
argo_set() {
  emulate -L zsh
  local repo="${PS_ARGOCD_REPO:-$HOME/Documents/projects/ps-argocd-dev-envs}"
  local registry="${ARGO_SET_REGISTRY:-ghcr.io/ps-prod/}"

  if [[ $# -lt 3 ]]; then
    echo "usage: argo_set <branch> <imageTag> <service[:imageName]> [service2 ...]" >&2
    return 1
  fi
  command -v git     >/dev/null 2>&1 || { echo "argo_set: git not found" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "argo_set: python3 not found" >&2; return 1; }
  [[ -d "$repo/.git" ]] || { echo "argo_set: repo not found: $repo" >&2; return 1; }

  local helper="${DEV_ENV_ROOT:-$HOME/Documents/projects/dev-env}/scripts/ps-agent/bin/argo-set-image.py"
  [[ -f "$helper" ]] || { echo "argo_set: helper not found: $helper" >&2; return 1; }

  local branch="$1"; shift
  local tag="$1";    shift
  local values="environments/$branch/values.yaml"

  # Env branches are rewritten by CI, so a local copy always diverges. Hard-sync
  # to origin before editing so the push is a clean fast-forward on top of HEAD.
  git -C "$repo" fetch --quiet origin "$branch" \
    || { echo "argo_set: fetch failed for '$branch'" >&2; return 1; }
  git -C "$repo" checkout --quiet -B "$branch" "origin/$branch" \
    || { echo "argo_set: checkout failed for '$branch'" >&2; return 1; }
  [[ -f "$repo/$values" ]] \
    || { echo "argo_set: $values not found (bad branch/env name?)" >&2; return 1; }

  # Surgical text edit (see argo-set-image.py) — keeps the diff minimal and
  # comments intact, unlike a YAML round-tripper that reformats the whole file.
  python3 "$helper" "$repo/$values" "$registry" "$tag" "$@" \
    || { echo "argo_set: image edit failed" >&2; return 1; }
  local svc
  for svc in "$@"; do
    echo "[argo_set] ${svc%%:*} -> ${registry}${svc##*:}:${tag}"
  done

  if git -C "$repo" diff --quiet -- "$values"; then
    echo "[argo_set] no change (already set to $tag)"
    return 0
  fi

  if [[ -n "$ARGO_SET_DRY" ]]; then
    echo "[argo_set] ARGO_SET_DRY set — diff only, not pushing:"
    git -C "$repo" --no-pager diff -- "$values"
    return 0
  fi

  git -C "$repo" add "$values"
  git -C "$repo" commit --quiet -m "$branch: set image(s) to $tag [$*]"
  git -C "$repo" push --quiet origin "$branch" \
    && echo "[argo_set] pushed '$branch' — ArgoCD will sync"
}
