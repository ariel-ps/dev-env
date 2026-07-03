# AI coding agent helpers - dot-sourced by init.ps1

function claude-danger {
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Error "claude-danger: claude CLI not found on PATH"
        return
    }

    & claude --dangerously-skip-permissions @args
}

function codex-danger {
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        Write-Error "codex-danger: codex CLI not found on PATH"
        return
    }

    & codex --dangerously-bypass-approvals-and-sandbox @args
}
