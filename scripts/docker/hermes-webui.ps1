# hermes-webui — run the Hermes WebUI in Docker via docker compose (Windows)
# Mirrors hermes-webui.sh.
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
# Serves on http://localhost:8787.
# Clone location: $env:HERMES_WEBUI_DIR or $env:LOCALAPPDATA\hermes-webui.

function hermes-webui {
    param([string]$Command = "start", [string]$Extra)

    $repoUrl  = "https://github.com/nesquena/hermes-webui.git"
    $repoDir  = if ($env:HERMES_WEBUI_DIR) { $env:HERMES_WEBUI_DIR } else { "$env:LOCALAPPDATA\hermes-webui" }
    $url      = "http://localhost:8787"

    function _hw_need_docker {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Error "[hermes-webui] docker not found on PATH"; return $false
        }
        docker info 2>$null | Out-Null
        if ($LASTEXITCODE) { Write-Error "[hermes-webui] Docker daemon not running — start Docker Desktop"; return $false }
        return $true
    }
    function _hw_ensure_repo {
        if (Test-Path "$repoDir\.git") { return $true }
        Write-Host "[hermes-webui] cloning $repoUrl -> $repoDir"
        New-Item -ItemType Directory -Force -Path (Split-Path $repoDir) | Out-Null
        git clone $repoUrl $repoDir; return (-not $LASTEXITCODE)
    }
    function _hw_ensure_env {
        $hermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { "$env:USERPROFILE\.hermes" }
        $workspace  = if ($env:HERMES_WORKSPACE) { $env:HERMES_WORKSPACE } else { "$env:USERPROFILE\workspace" }
        New-Item -ItemType Directory -Force -Path $hermesHome, $workspace | Out-Null
        @("HERMES_HOME=$hermesHome", "HERMES_WORKSPACE=$workspace") | Set-Content "$repoDir\.env"
    }
    function _hw_compose { docker compose -f "$repoDir\docker-compose.yml" @args }

    switch ($Command) {
        "start" {
            if (-not (_hw_need_docker)) { return }
            if (-not (_hw_ensure_repo)) { return }
            _hw_ensure_env
            Write-Host "[hermes-webui] building & starting..."
            _hw_compose up -d --build
            Write-Host "[hermes-webui] up -> $url   (logs: hermes-webui logs | stop: hermes-webui stop)"
        }
        "stop" {
            if (-not (_hw_need_docker)) { return }
            _hw_compose down
        }
        "restart" { hermes-webui stop; hermes-webui start }
        "logs"    {
            if (-not (_hw_need_docker)) { return }
            _hw_compose logs -f
        }
        "status"  {
            if (-not (_hw_need_docker)) { return }
            _hw_compose ps
        }
        "update"  {
            if (-not (_hw_need_docker)) { return }
            if (-not (_hw_ensure_repo)) { return }
            git -C $repoDir pull --ff-only
            _hw_ensure_env
            _hw_compose up -d --build
            Write-Host "[hermes-webui] updated -> $url"
        }
        "open"    { Start-Process $url }
        { $_ -in "help","-h","--help" } {
            Write-Host "usage: hermes-webui {start|stop|restart|logs|status|update|open}"
        }
        default   { Write-Error "[hermes-webui] unknown command '$Command' (try: start stop restart logs status update open)" }
    }
}
