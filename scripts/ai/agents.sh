# AI coding agent helpers - sourced by init.zsh

claude-danger() {
  command -v claude >/dev/null 2>&1 || { echo "claude-danger: claude CLI not found on PATH" >&2; return 1; }
  claude --dangerously-skip-permissions "$@"
}

codex-danger() {
  command -v codex >/dev/null 2>&1 || { echo "codex-danger: codex CLI not found on PATH" >&2; return 1; }
  codex --dangerously-bypass-approvals-and-sandbox "$@"
}

# Leaked system-prompt collection (elder-plinius/CL4R1T4S), cached under ~/.cache.
CL4R1T4S_REPO="${CL4R1T4S_REPO:-https://github.com/elder-plinius/CL4R1T4S.git}"
CL4R1T4S_DIR="${CL4R1T4S_DIR:-$HOME/.cache/CL4R1T4S}"

# Clone the prompt repo on first run, fast-forward it on later runs.
cl4r1t4s-sync() {
  command -v git >/dev/null 2>&1 || { echo "cl4r1t4s-sync: git not found on PATH" >&2; return 1; }
  if [ -d "$CL4R1T4S_DIR/.git" ]; then
    git -C "$CL4R1T4S_DIR" pull --ff-only
  else
    mkdir -p "${CL4R1T4S_DIR:h}" && git clone "$CL4R1T4S_REPO" "$CL4R1T4S_DIR"
  fi
}

# Pick a system prompt from the cache and launch claude with it (danger mode).
# Extra args pass through to claude, e.g. claude-persona -p "hi".
claude-persona() {
  command -v claude >/dev/null 2>&1 || { echo "claude-persona: claude CLI not found on PATH" >&2; return 1; }
  [ -d "$CL4R1T4S_DIR" ] || { echo "claude-persona: prompt cache missing — run cl4r1t4s-sync" >&2; return 1; }

  local -a prompts
  prompts=("${(@f)$(cd "$CL4R1T4S_DIR" && find . -type f \( -name '*.md' -o -name '*.txt' \) ! -path './.git/*' | sed 's|^\./||' | sort)}")
  (( ${#prompts} )) || { echo "claude-persona: no prompt files under $CL4R1T4S_DIR" >&2; return 1; }

  local pick
  if command -v fzf >/dev/null 2>&1; then
    pick=$(printf '%s\n' "${prompts[@]}" | fzf --prompt='system prompt> ') || return 1
  else
    local choice PS3='Pick system prompt #: '
    select choice in "${prompts[@]}"; do
      [ -n "$choice" ] && { pick=$choice; break; }
    done
  fi
  [ -n "$pick" ] || return 1

  echo "claude-persona: loading $pick" >&2
  claude --dangerously-skip-permissions --system-prompt-file "$CL4R1T4S_DIR/$pick" "$@"
}
