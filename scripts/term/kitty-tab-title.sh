# Put the kitty pane title back to the shell's location once an agent is done with
# the pane. Counterpart to scripts/term/bin/kitty-agent-title, which stamps
# "C repo/branch ⚙" while claude/codex runs.
#
# The hook sets the title permanently via `kitten @ set-window-title` (a
# --temporary title loses instantly to the agent's own OSC output), so a plain OSC
# escape from this shell cannot take it back — the override has to be cleared with
# a no-arg set-window-title. That costs a subprocess, so it only runs when the hook
# left its breadcrumb behind, not on every prompt.

if [[ -o interactive ]] && [[ -n ${KITTY_WINDOW_ID:-} ]]; then
  autoload -Uz add-zsh-hook

  __kitty_reset_title() {
    emulate -L zsh

    local dir=${TMPDIR:-/tmp}/kitty-agent-title
    local flag
    for flag in $dir/win-${KITTY_WINDOW_ID}.window(N) $dir/win-${KITTY_WINDOW_ID}.tab(N); do
      command rm -f -- $flag
      if [[ $flag == *.tab ]]; then
        kitten @ set-tab-title >/dev/null 2>&1
      else
        kitten @ set-window-title >/dev/null 2>&1
      fi
    done

    # %3~ gives the ~-abbreviated cwd capped at 3 components, so deep paths don't
    # push everything else out of the tab bar.
    print -n -- $'\e]2;'"${(%):-%3~}"$'\a'
  }

  # Registering a precmd hook is a top-level side effect, which the repo
  # conventions otherwise forbid — there is no way around it for a prompt hook.
  # It is harmless under Claude Code's shell snapshot: the snapshot replays
  # function bodies only, and a Bash tool call never draws a prompt, so the
  # registration simply does not happen there.
  add-zsh-hook precmd __kitty_reset_title
fi
