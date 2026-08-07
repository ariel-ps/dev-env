#!/usr/bin/env bash
# Claude Code statusline: a colored [name] badge naming THIS pane, plus model + cwd.
#
# Same idea as claude-profiles/statusline.sh, which badges the active profile — this
# badges the pane's cx identity instead, so a focused or zoomed pane still says which
# agent it is when the kitty tab bar is not visible. Nine panes in a grid are
# otherwise indistinguishable once one is maximised.
#
# Name resolution, first hit wins:
#   CX_NAME              — set at launch by kitty-grid (`--env CX_NAME=<label>-<i>`)
#   the cx registry      — for panes that named themselves via `cx register`
#   the cwd's basename    — plain fallback
#
# Wire it up with:
#   "statusLine": { "type": "command",
#                   "command": "~/Documents/projects/dev-env/scripts/cx/bin/cx-statusline.sh" }
#
# Composition: set CX_STATUSLINE_EXTRA to another statusline command and its output
# is appended, so this can carry e.g. the caveman mode badge rather than replacing
# it — Claude Code allows only one statusLine, so chaining is the only way to show
# two things.

# Session JSON arrives on stdin, and is needed twice (here and by any EXTRA
# command), so capture rather than stream it.
in="$(cat 2>/dev/null || true)"

field() {
  printf '%s' "$in" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

model="$(field display_name)"
cwd="$(field current_dir)"

name="${CX_NAME:-}"

# Fall back to whatever this pane called itself when it registered. Grepping the
# record beats invoking cx.py: a statusline runs on every redraw, so a Python
# start-up per frame is too expensive to justify.
if [ -z "$name" ] && [ -n "${KITTY_WINDOW_ID:-}" ]; then
  rec="${CX_STATE_DIR:-$HOME/.claude/cx}/panes/${KITTY_WINDOW_ID}.json"
  [ -r "$rec" ] && name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$rec" | head -1)"
fi

[ -z "$name" ] && name="${cwd##*/}"
[ -z "$name" ] && name="claude"

# Stable colour per name (sum of char codes) so a given pane keeps its colour for
# the whole session instead of flickering between redraws.
sum=0
i=0
n=${#name}
while [ "$i" -lt "$n" ]; do
  c="${name:$i:1}"
  sum=$((sum + $(printf '%d' "'$c")))
  i=$((i + 1))
done
bg=$((41 + sum % 6))

printf '\033[1;97;%dm %s \033[0m' "$bg" "$name"
[ -n "$model" ] && printf ' \033[2m%s\033[0m' "$model"
[ -n "$cwd" ] && printf ' \033[2m%s\033[0m' "${cwd##*/}"

if [ -n "${CX_STATUSLINE_EXTRA:-}" ]; then
  extra="$(printf '%s' "$in" | eval "$CX_STATUSLINE_EXTRA" 2>/dev/null)"
  [ -n "$extra" ] && printf ' %s' "$extra"
fi

printf '\n'
