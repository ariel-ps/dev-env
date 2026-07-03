# openspec-ui — run the OpenSpec UI dashboard in Docker (Windows)
# Mirrors openspec-ui.sh.
#
# Usage:
#   openspec-ui [start] [project-dir]   build (if needed) & start
#   openspec-ui stop                    stop & remove the container
#   openspec-ui restart [project-dir]   stop then start
#   openspec-ui logs                    follow container logs
#   openspec-ui status                  show container state
#   openspec-ui build                   clone/pull repo & (re)build image
#   openspec-ui open                    open the UI in the browser
#
# Serves on http://localhost:3000 (override with $env:OPENSPEC_UI_PORT).
# Clone location: $env:OPENSPEC_UI_DIR or $env:LOCALAPPDATA\openspec-ui.

function openspec-ui {
    param([string]$Command = "start", [string]$ProjectDir)

    $repoUrl   = "https://github.com/ToruAI/openspec-ui.git"
    $repoDir   = if ($env:OPENSPEC_UI_DIR) { $env:OPENSPEC_UI_DIR } else { "$env:LOCALAPPDATA\openspec-ui" }
    $image     = "openspec-ui"
    $container = "openspec-ui"
    $port      = if ($env:OPENSPEC_UI_PORT) { $env:OPENSPEC_UI_PORT } else { "3000" }
    $configDir = "$env:USERPROFILE\.config\openspec-ui"
    $configFile= "$configDir\openspec-ui.json"
    $url       = "http://localhost:$port"

    function _osu_need_docker {
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Write-Error "[openspec-ui] docker not found on PATH"; return $false
        }
        docker info 2>$null | Out-Null
        if ($LASTEXITCODE) { Write-Error "[openspec-ui] Docker daemon not running — start Docker Desktop"; return $false }
        return $true
    }
    function _osu_ensure_repo {
        if (Test-Path "$repoDir\.git") { return $true }
        Write-Host "[openspec-ui] cloning $repoUrl -> $repoDir"
        New-Item -ItemType Directory -Force -Path (Split-Path $repoDir) | Out-Null
        git clone $repoUrl $repoDir; return (-not $LASTEXITCODE)
    }
    function _osu_ensure_image {
        docker image inspect $image 2>$null | Out-Null
        if (-not $LASTEXITCODE) { return $true }
        if (-not (_osu_ensure_repo)) { return $false }
        Write-Host "[openspec-ui] building image '$image' (first run)..."
        docker build -t $image $repoDir; return (-not $LASTEXITCODE)
    }
    function _osu_write_config([string]$Name) {
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
        @"
{
  "sources": [
    { "name": "$Name", "path": "/repos/openspec" }
  ],
  "port": 3000
}
"@ | Set-Content $configFile
    }

    switch ($Command) {
        "start" {
            if (-not (_osu_need_docker)) { return }
            $proj = if ($ProjectDir) { Resolve-Path $ProjectDir } else { $PWD.Path }
            if (-not (Test-Path $proj)) { Write-Error "[openspec-ui] no such directory: $proj"; return }
            if (-not (Test-Path "$proj\openspec")) {
                Write-Warning "[openspec-ui] '$proj' has no openspec\ dir — dashboard will be empty"
            }
            if (-not (_osu_ensure_image)) { return }
            _osu_write_config (Split-Path $proj -Leaf)
            docker rm -f $container 2>$null | Out-Null
            Write-Host "[openspec-ui] starting on '$proj'..."
            docker run -d --name $container `
                -p "${port}:3000" `
                -v "${proj}:/repos" `
                -v "${configFile}:/app/openspec-ui.json" `
                $image | Out-Null
            Write-Host "[openspec-ui] up -> $url   (logs: openspec-ui logs | stop: openspec-ui stop)"
        }
        "stop" {
            if (-not (_osu_need_docker)) { return }
            docker rm -f $container 2>$null | Out-Null
            Write-Host "[openspec-ui] stopped"
        }
        "restart" { openspec-ui stop; openspec-ui start $ProjectDir }
        "logs"    {
            if (-not (_osu_need_docker)) { return }
            docker logs -f $container
        }
        "status"  {
            if (-not (_osu_need_docker)) { return }
            docker ps -a --filter "name=^/$container$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
        }
        "build"   {
            if (-not (_osu_need_docker)) { return }
            if (-not (_osu_ensure_repo)) { return }
            git -C $repoDir pull --ff-only
            Write-Host "[openspec-ui] building image '$image'..."
            docker build -t $image $repoDir
            Write-Host "[openspec-ui] image built — run: openspec-ui start"
        }
        "open"    { Start-Process $url }
        { $_ -in "help","-h","--help" } {
            Write-Host "usage: openspec-ui {start [dir]|stop|restart [dir]|logs|status|build|open}"
        }
        default   { Write-Error "[openspec-ui] unknown command '$Command' (try: start stop restart logs status build open)" }
    }
}
