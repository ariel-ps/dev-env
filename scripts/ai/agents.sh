# AI coding agent helpers - sourced by init.zsh

claude-danger() {
  command -v claude >/dev/null 2>&1 || { echo "claude-danger: claude CLI not found on PATH" >&2; return 1; }
  claude --dangerously-skip-permissions "$@"
}

codex-danger() {
  command -v codex >/dev/null 2>&1 || { echo "codex-danger: codex CLI not found on PATH" >&2; return 1; }
  codex --dangerously-bypass-approvals-and-sandbox "$@"
}
