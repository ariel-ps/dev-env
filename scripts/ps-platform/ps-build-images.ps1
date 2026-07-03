# ps-build-images — dispatch the ps-platform image-build workflow (Windows)
# Mirrors ps-build-images.sh. Requires: gh (authenticated), git.
#
# Usage:
#   ps-build-images [options]
#
# Options:
#   -Branch <branch>    Branch to build (default: current git branch)
#   -NoWatch            Dispatch and return without watching
#   -ImagesOnly         Do not dispatch; print images from the latest run
#   -Repo <repo>        GitHub repo (default: $env:PS_PLATFORM_REPO or prompt-security/ps-platform)
#   -Help               Show help

function ps-build-images {
    param(
        [Alias("b")][string]$Branch,
        [Alias("n")][switch]$NoWatch,
        [switch]$ImagesOnly,
        [string]$Repo,
        [Alias("h")][switch]$Help
    )

    $repo     = if ($Repo) { $Repo } elseif ($env:PS_PLATFORM_REPO) { $env:PS_PLATFORM_REPO } else { "prompt-security/ps-platform" }
    $workflow = if ($env:PS_PLATFORM_IMAGE_WORKFLOW) { $env:PS_PLATFORM_IMAGE_WORKFLOW } else { "build-push-docker-image-ps-platform.yml" }

    if ($Help) {
        Write-Host @"
ps-build-images — build & push ps-platform branch images via GitHub Actions,
then print the GHCR image names.

Usage:
  ps-build-images [options]

Options:
  -Branch <branch>    Branch to build (default: current git branch)
  -NoWatch            Dispatch only, do not watch
  -ImagesOnly         Do not dispatch; print images of the latest run
  -Repo <repo>        GitHub repo (default: prompt-security/ps-platform)
  -Help               Show this help

Examples:
  ps-build-images
  ps-build-images -Branch my-feature
  ps-build-images -Branch my-feature -NoWatch
  ps-build-images -ImagesOnly
"@
        return
    }

    function _psbi_need {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            Write-Error "[ps-build-images] gh CLI not found on PATH"; return $false
        }
        gh auth status 2>$null | Out-Null
        if ($LASTEXITCODE) { Write-Error "[ps-build-images] gh not authenticated — run 'gh auth login'"; return $false }
        return $true
    }
    function _psbi_tag([string]$b) { $b -replace '[^a-zA-Z0-9_]', '-' }
    function _psbi_curbranch { git rev-parse --abbrev-ref HEAD 2>$null }
    function _psbi_services([string]$RunId) {
        gh run view $RunId --repo $repo --json jobs --jq '.jobs[].name' 2>$null |
            Select-String 'build-and-push \(([a-z0-9_-]+)\)' |
            ForEach-Object { $_.Matches.Groups[1].Value } | Sort-Object -Unique
    }
    function _psbi_print_images([string]$RunId, [string]$Br) {
        $tag      = _psbi_tag $Br
        $services = _psbi_services $RunId
        if (-not $services) {
            Write-Error "[ps-build-images] no built services found for run $RunId"
            return $false
        }
        Write-Host "Images pushed (tag: $tag):"
        $services | ForEach-Object {
            Write-Host "  ghcr.io/ps-prod/$_`:$tag"
            Write-Host "  ghcr.io/ps-customers/$_`:$tag"
        }
        return $true
    }

    if (-not (_psbi_need)) { return }

    if (-not $Branch) { $Branch = _psbi_curbranch }
    if (-not $Branch) { Write-Error "[ps-build-images] no -Branch given and not in a git repo"; return }

    if ($ImagesOnly) {
        $runId = gh run list --repo $repo --workflow $workflow --branch $Branch `
            --limit 1 --json databaseId --jq '.[0].databaseId' 2>$null
        if (-not $runId) { Write-Error "[ps-build-images] no image-build run found for branch '$Branch'"; return }
        _psbi_print_images $runId $Branch
        return
    }

    Write-Host "[ps-build-images] dispatching $workflow on $repo @ $Branch ..."
    gh workflow run $workflow --repo $repo --ref $Branch -f build_image=true
    if ($LASTEXITCODE) { return }

    $runId = ""
    1..10 | ForEach-Object {
        if (-not $runId) {
            $runId = gh run list --repo $repo --workflow $workflow --branch $Branch `
                --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId' 2>$null
            if (-not $runId) { Start-Sleep 2 }
        }
    }
    if (-not $runId) {
        Write-Error "[ps-build-images] dispatched, but could not locate the run — try: gh run list --repo $repo --workflow $workflow"
        return
    }

    Write-Host "[ps-build-images] run: https://github.com/$repo/actions/runs/$runId"
    if ($NoWatch) {
        Write-Host "[ps-build-images] dispatched (not watching). When done: ps-build-images -ImagesOnly -Branch $Branch"
        return
    }

    gh run watch $runId --repo $repo --exit-status
    $rc = $LASTEXITCODE
    Write-Host ""
    _psbi_print_images $runId $Branch
    if ($rc) { Write-Warning "[ps-build-images] run did not finish successfully (exit $rc) — image list may be incomplete" }
}
