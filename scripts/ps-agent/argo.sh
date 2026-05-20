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
