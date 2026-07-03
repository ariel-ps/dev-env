# argo / AWS non-prod session helper (Windows)
# Mirrors argo.sh — requires aws CLI and gh CLI on PATH.

function argo_env_start {
    param([string]$Profile = "nonprod")
    if (aws sts get-caller-identity --profile $Profile 2>$null) {
        Write-Host "[argo_env_start] SSO session for '$Profile' still valid"
    } else {
        Write-Host "[argo_env_start] logging in to SSO for '$Profile'..."
        aws sso login --profile $Profile; if ($LASTEXITCODE) { return }
    }
    $env:AWS_PROFILE = $Profile
    Write-Host "[argo_env_start] AWS_PROFILE=$env:AWS_PROFILE"
    aws sts get-caller-identity
}

function argo_env_stop {
    Remove-Item Env:AWS_PROFILE -ErrorAction SilentlyContinue
    Write-Host "[argo_env_stop] AWS_PROFILE unset"
}

function argo_npm_login {
    param([string]$Profile = "nonprod")
    argo_env_start $Profile | Out-Null; if ($LASTEXITCODE) { return }
    aws codeartifact login --tool npm --domain prompt-security `
        --repository npm-proxy --region eu-north-1 --profile $Profile
}

function argo_pip_login {
    param([string]$Profile = "nonprod")
    argo_env_start $Profile | Out-Null; if ($LASTEXITCODE) { return }
    aws codeartifact login --tool pip --domain prompt-security `
        --repository pypi-proxy --region eu-north-1 --profile $Profile
}

function argo_create_env {
    param([string]$Ttl = "8", [string]$PromptVersion = "")
    gh workflow run create_env.yml `
        -R prompt-security/ps-argocd-dev-envs `
        --ref main `
        -f ttl_hours=$Ttl `
        -f instance_type=spot `
        -f gpu=false `
        -f prompt_version=$PromptVersion `
        -f icap=false `
        -f empty_env=false `
        -f additional_setup=false `
        -f shared_gpu=true
    if (-not $LASTEXITCODE) { Write-Host "[argo_create_env] dispatched (ttl=${Ttl}h)" }
}

function argo_delete_env {
    param([string]$Additional = "false")
    gh workflow run delete_env.yml `
        -R prompt-security/ps-argocd-dev-envs `
        --ref main `
        -f additional_setup=$Additional
    if (-not $LASTEXITCODE) { Write-Host "[argo_delete_env] dispatched (additional_setup=$Additional)" }
}

function argo_env_status {
    param([int]$Limit = 1)
    $me = gh api user --jq .login; if ($LASTEXITCODE) { return }
    gh run list -R prompt-security/ps-argocd-dev-envs --user=$me --limit $Limit
}
