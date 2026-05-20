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
