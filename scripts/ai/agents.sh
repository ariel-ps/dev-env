# AI coding agent helpers - sourced by init.zsh

claude-danger() {
  command -v claude >/dev/null 2>&1 || { echo "claude-danger: claude CLI not found on PATH" >&2; return 1; }
  claude --dangerously-skip-permissions "$@"
}

codex-danger() {
  command -v codex >/dev/null 2>&1 || { echo "codex-danger: codex CLI not found on PATH" >&2; return 1; }
  codex --dangerously-bypass-approvals-and-sandbox "$@"
}

# __kitty_agent_grid <function-name> [count] [label] — open a new kitty tab with
# <count> windows (default 9, i.e. 3x3), each running the given shell
# function via `zsh -lic` (so claude-danger/codex-danger resolve from rc),
# then apply kitty's grid layout for equal-size panes.
#
# Panes are addressed as NATS-style subjects <label>.1..<label>.N, and each gets
# its own background colour. <label> defaults to the current directory's name (or
# "home" in $HOME). Address one pane or the whole grid:
#   cx send bench.3 "..."      one pane
#   cx send 'bench.*' "..."    every pane in the grid
#
# usage: kitty-grid-claude-danger [count] [label]
#   kitty-grid-claude-danger            # 9 panes, subjects <cwd-name>.1..9
#   kitty-grid-claude-danger 4 bench    # 4 panes, subjects bench.1..bench.4
#   KITTY_GRID_NO_COLOR=1 kitty-grid-claude-danger   # skip the ~2.5s colouring
#
# DANGER: every pane runs an unsupervised agent with permission checks
# bypassed (--dangerously-skip-permissions / --dangerously-bypass-approvals-
# and-sandbox). N agents acting on the same cwd with no confirmation gate.
# Requires kitty remote control (allow_remote_control in kitty.conf).
__kitty_agent_grid() {
  local cmd="$1" want="${2:-9}" label="${3:-}"
  [[ "$want" =~ '^[0-9]+$' ]] \
    || { echo "kitty-grid-${cmd}: count must be a number, got: $want" >&2; return 1; }

  # The label is the middle token of every pane's subject. Default to the cwd's
  # name so a grid reads like the directory it works on — except in $HOME, where
  # that is the username: long, repeated N times, and saying nothing about what the
  # grid is for.
  if [[ -z "$label" ]]; then
    if [[ "$PWD" == "$HOME" ]]; then
      label=home
    else
      label="${PWD:t}"
    fi
  fi
  label="${label//[^A-Za-z0-9._-]/-}"
  [[ -n "$label" ]] \
    || { echo "kitty-grid-${cmd}: could not derive a usable label; pass one explicitly" >&2; return 1; }
  command -v kitty >/dev/null 2>&1 \
    || { echo "kitty-grid-${cmd}: kitty not found" >&2; return 1; }
  kitty @ ls >/dev/null 2>&1 \
    || { echo "kitty-grid-${cmd}: kitty remote control unavailable (enable allow_remote_control in kitty.conf)" >&2; return 1; }

  # Capture the new tab by the id of its first window instead of relying on
  # "the active/focused tab" — that's wrong whenever this doesn't run from a
  # tab that currently has real OS focus (multiple kitty OS windows, or
  # invoked non-interactively), so goto-layout/set-window-title would land
  # on the wrong tab (or none) below.
  # `-lic`, not `-ic`: a pane spawned by `kitty @ launch` inherits kitty's own
  # environment, which for a Dock-launched kitty is the minimal launchd PATH.
  # /opt/homebrew/bin arrives only via the LOGIN files — ~/.zprofile's
  # `brew shellenv` and /etc/zprofile's path_helper — which a non-login `-ic`
  # shell never sources. The agent then starts fine (claude is in ~/.local/bin)
  # but every node-based hook inside it dies with "node: command not found",
  # silently disabling those plugins for the whole session.
  # Each pane is told its subject at launch, as a label plus its own index, which
  # both agent hooks read back:
  #   cx register builds <host>.<label>.<index> from them instead of guessing from
  #     cwd — which labels every pane of a grid identically (the cwd is shared) and
  #     then separates them by a name collision counter unrelated to the pane.
  #   kitty-agent-title titles the pane with the same subject, so `cx ls` and the
  #     tab bar show one string rather than two names for one pane.
  # KITTY_AGENT_TITLE_PREFIX only applies when no CX_NAME is set; with a subject the
  # index is already in the name.
  #
  # NOT the cx slot. Slots are unique across every session on the machine, pane
  # indexes only within their grid, so pane 2 wants slot 2 while an unrelated
  # session already holds it — they cannot be made to agree. Address grid panes by
  # subject (`cx send <label>.2`); the slot is just a short integer for typing.
  local first_id
  first_id=$(kitty @ launch --type=tab --tab-title="$label" --cwd=current \
    --env "KITTY_AGENT_TITLE_PREFIX=1" --env "CX_NAME=${label}" --env "CX_INDEX=1" \
    -- zsh -lic "$cmd") \
    || { echo "kitty-grid-${cmd}: failed to launch tab" >&2; return 1; }

  local -i i
  for ((i = 2; i <= want; i++)); do
    kitty @ launch --match "id:$first_id" --cwd=current \
      --env "KITTY_AGENT_TITLE_PREFIX=$i" --env "CX_NAME=${label}" --env "CX_INDEX=$i" \
      -- zsh -lic "$cmd" >/dev/null
  done

  kitty @ goto-layout --match "window_id:$first_id" grid

  # Give each pane its own background, so panes are told apart by colour as well
  # as by number — the reason kitty-colorize-panes exists, and it was never wired
  # to the launcher that creates the panes. After goto-layout, so the pane set is
  # final. Costs ~2.5s for 9 panes (the theme GA searches ~400 palettes); set
  # KITTY_GRID_NO_COLOR=1 to skip it.
  #
  # Best-effort throughout: it needs the theme cache (kitty-themes-sync) and lives
  # in another profile's file, so a missing helper must not fail a launched grid.
  if [[ -z "${KITTY_GRID_NO_COLOR:-}" ]] && (( $+functions[kitty-colorize-panes] )); then
    # colorize wants a TAB id; first_id is a window id, and `window_id:` is the
    # tab-matcher that resolves "the tab containing this window".
    local tab_id
    tab_id=$(kitty @ ls --match-tab "window_id:$first_id" 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
print(data[0]["tabs"][0]["id"]) if data else sys.exit(1)
' 2>/dev/null)
    [[ -n "$tab_id" ]] && kitty-colorize-panes "$tab_id" >/dev/null 2>&1
  fi

  echo "kitty-grid-${cmd}: ${want}x ${cmd}, subjects ${label}.1..${label}.${want}, new tab, grid layout"
}

kitty-grid-claude-danger() { __kitty_agent_grid claude-danger "${1:-9}" "${2:-}"; }
kitty-grid-codex-danger()  { __kitty_agent_grid codex-danger  "${1:-9}" "${2:-}"; }

# aoe-grid-claude-danger [count] [label] — open a new kitty tab with <count>
# claude sessions (yolo/danger mode) created and tracked by aoe (tmux-backed),
# one per pane, arranged in kitty's grid layout. Each pane runs `aoe session
# attach` for its own session rather than the bare `aoe` TUI dashboard, so
# only the running claude terminal is visible in each pane — no aoe
# sidebar/session-list chrome ("the left panel").
#
# Sessions are titled <label>-1..<label>-N, where <label> defaults to the
# current directory's name — so they read like the rest of your aoe dashboard
# (dev-env-1, pr-6322-3) instead of carrying an opaque pid.
#
# usage: aoe-grid-claude-danger [count] [label]
#   aoe-grid-claude-danger              # 9 panes, titled <cwd-name>-1..9
#   aoe-grid-claude-danger 4            # 4 panes, titled <cwd-name>-1..4
#   aoe-grid-claude-danger 9 refactor   # 9 panes, titled refactor-1..9
#
# DANGER: every pane runs an unsupervised claude session with permission
# checks bypassed (aoe --yolo == claude --dangerously-skip-permissions), and
# --trust-hooks so aoe never blocks on a hook/MCP-trust prompt with no TTY
# to answer it. <count> agents acting on the same cwd with no confirmation
# gate.
# Requires: aoe, kitty remote control (allow_remote_control in kitty.conf).
aoe-grid-claude-danger() {
  local want="${1:-9}"
  [[ "$want" =~ '^[0-9]+$' ]] \
    || { echo "aoe-grid-claude-danger: count must be a number, got: $want" >&2; return 1; }
  (( want > 0 )) \
    || { echo "aoe-grid-claude-danger: count must be at least 1" >&2; return 1; }

  # Default to the cwd's basename, and squash anything that would make an
  # awkward tmux session name (aoe derives the tmux name from the title).
  local label="${2:-${PWD:t}}"
  label="${label//[^A-Za-z0-9._-]/-}"
  [[ -n "$label" ]] \
    || { echo "aoe-grid-claude-danger: could not derive a usable label; pass one explicitly" >&2; return 1; }

  command -v aoe >/dev/null 2>&1 \
    || { echo "aoe-grid-claude-danger: aoe not found" >&2; return 1; }
  command -v kitty >/dev/null 2>&1 \
    || { echo "aoe-grid-claude-danger: kitty not found" >&2; return 1; }
  kitty @ ls >/dev/null 2>&1 \
    || { echo "aoe-grid-claude-danger: kitty remote control unavailable (enable allow_remote_control in kitty.conf)" >&2; return 1; }

  # aoe shells out to tmux itself; if this shell's PATH doesn't carry Homebrew's
  # bin dir (seen in some kitty-pane shells and non-login script contexts),
  # `aoe add`/`aoe session start` fail with a bare "No such file or directory"
  # that gives no hint it's tmux that's missing. Patch PATH locally rather
  # than assume the caller's shell already has it.
  #
  # `local -x`, NOT plain `local`: in zsh a plain `local PATH=...` is visible
  # to this shell (so `command -v tmux` starts passing and looks fixed) but is
  # NOT exported, so the aoe child process still gets the unpatched PATH and
  # keeps failing with the same opaque error. -x exports it.
  # Note this shell's PATH genuinely lacks tmux on this machine (Homebrew's
  # /opt/homebrew/bin is absent from the interactive zsh PATH), so this is the
  # normal path, not a rare fallback — and it has to be re-applied inside each
  # kitty pane too, see pane_prefix below.
  local tmux_dir=""
  if ! command -v tmux >/dev/null 2>&1; then
    if [[ -x /opt/homebrew/bin/tmux ]]; then
      tmux_dir=/opt/homebrew/bin
      local -x PATH="$PATH:$tmux_dir"
    else
      echo "aoe-grid-claude-danger: tmux not found on PATH or at /opt/homebrew/bin/tmux" >&2
      return 1
    fi
  fi

  # Refuse to start if any target title is already taken: aoe keys sessions by
  # id, not title, so it would happily create a second `dev-env-3` and leave
  # two indistinguishable rows in the dashboard (and an ambiguous
  # `aoe session attach dev-env-3`). Cheaper to stop and let the caller pick a
  # label than to untangle that after the fact.
  local -a clashes
  clashes=("${(@f)$(aoe list --json 2>/dev/null | python3 -c '
import json, sys
want, label = int(sys.argv[1]), sys.argv[2]
titles = {s.get("title", "") for s in json.load(sys.stdin)}
for i in range(1, want + 1):
    t = f"{label}-{i}"
    if t in titles:
        print(t)
' "$want" "$label" 2>/dev/null)}")
  clashes=("${(@)clashes:#}")
  if (( ${#clashes[@]} )); then
    echo "aoe-grid-claude-danger: these session titles already exist: ${clashes[*]}" >&2
    echo "aoe-grid-claude-danger: pass a different label, e.g. aoe-grid-claude-danger $want ${label}-b" >&2
    return 1
  fi

  # All loop-body locals are declared here, once. Re-running a valueless
  # `local x y` for an already-declared local makes zsh *print* its current
  # value (typeset-display behavior), so declaring these inside the loop
  # leaks `sess_id=...`/`tmux_name=...` noise to stdout on every iteration
  # after the first.
  local -a titles
  local -i i tries start_tries
  local title sess_status sess_id tmux_name
  for ((i = 1; i <= want; i++)); do
    title="${label}-${i}"
    # Deliberately no -l here: `aoe add -l` tries to foreground-attach the
    # new tmux session immediately, in THIS shell — confirmed to either error
    # ("open terminal failed: not a terminal" with no TTY) or block this loop
    # until manually detached (with one). `aoe session start` is the
    # non-blocking, already-detached equivalent (confirmed: returns in
    # ~0.1s) — the actual interactive attach happens per-pane below, inside
    # kitty, where a real TTY exists.
    aoe add "$PWD" --tool claude --yolo --trust-hooks --title "$title" >/dev/null \
      || { echo "aoe-grid-claude-danger: aoe add failed for pane $i ($title)" >&2; return 1; }

    # `aoe session start` right after `aoe add` has a confirmed race in aoe
    # itself: the first call sometimes fails with a bare "No such file or
    # directory (os error 2)" even though the session record was just
    # created fine. It's genuinely flaky, not a fixed settle time — timed
    # trials saw anywhere from an instant first-try success to needing
    # several retries over a few seconds — so give it real margin rather
    # than a couple of quick retries.
    start_tries=0
    until aoe session start "$title" >/dev/null 2>&1; do
      (( ++start_tries >= 15 )) \
        && { echo "aoe-grid-claude-danger: aoe session start failed for pane $i ($title) after $start_tries tries" >&2; return 1; }
      sleep 1
    done

    # add/start both return before the launched claude process has
    # necessarily settled, so poll status instead of assuming success — a
    # bad launch (missing binary, broken cwd) should fail loudly here, not
    # get silently wired into a kitty pane that then attaches to a dead
    # session.
    tries=0
    sess_status="unknown"
    while (( tries < 10 )); do
      sess_status=$(aoe session show "$title" --json 2>/dev/null | python3 -c 'import json,sys
print(json.load(sys.stdin).get("status","unknown"))' 2>/dev/null)
      [[ "$sess_status" == error || "$sess_status" == idle || "$sess_status" == running || "$sess_status" == working ]] && break
      sleep 0.3
      (( tries++ ))
    done
    if [[ "$sess_status" == error ]]; then
      echo "aoe-grid-claude-danger: session $title entered error state after start" >&2
      return 1
    fi

    # aoe sets `remain-on-exit on` on its panes, which keeps a dead pane (and
    # so the whole tmux session) alive after claude exits — the attach never
    # returns and the kitty pane just sits there showing a corpse. Turn it off
    # for these grid sessions so exiting claude tears the session down and the
    # pane closes on its own. Resolve the tmux name by the id's first 8 chars
    # rather than rebuilding it from the title, since aoe truncates long
    # titles in the tmux session name.
    sess_id=$(aoe session show "$title" --json 2>/dev/null | python3 -c 'import json,sys
print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
    if [[ -n "$sess_id" ]]; then
      tmux_name=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -- "_${sess_id[1,8]}\$" | head -1)
      [[ -n "$tmux_name" ]] && tmux set-option -p -t "$tmux_name" remain-on-exit off 2>/dev/null
    fi

    titles+=("$title")
  done

  # Run the attach through `zsh -lic`, not as a bare command: a process spawned
  # by `kitty @ launch` inherits kitty's own minimal PATH
  # (/Applications/kitty.app/Contents/MacOS:/usr/bin:/bin:/usr/sbin:/sbin), so
  # `aoe` isn't even resolvable. It must be a LOGIN shell (`-l`): /opt/homebrew/bin
  # comes from ~/.zprofile's `brew shellenv` and /etc/zprofile's path_helper, and
  # a bare `-ic` shell sources neither — which left tmux unresolvable (hence
  # tmux_dir/pane_prefix below) and made every node-based hook in the agent fail
  # with "node: command not found". An aoe that can't run tmux reports the
  # misleading "Session is not running. Start it first" for a session that IS
  # running, then exits and the pane vanishes.
  # pane_prefix is kept as belt-and-braces for a tmux installed outside Homebrew.
  # `|| exec zsh`, not `; exec zsh`: fall back to a shell ONLY when attach
  # actually fails, so its error stays on screen instead of the pane vanishing
  # before it can be read. On a normal exit the pane must close, and it does —
  # tmux attach exits 0 both when detached and when its session is destroyed
  # (verified), so the `||` branch doesn't fire and kitty closes the window.
  local pane_prefix=""
  [[ -n "$tmux_dir" ]] && pane_prefix="export PATH=\"\$PATH:${tmux_dir}\"; "

  local first_id
  first_id=$(kitty @ launch --type=tab --tab-title="$label" --cwd=current \
    -- zsh -lic "${pane_prefix}aoe session attach ${(q)titles[1]} || exec zsh") \
    || { echo "aoe-grid-claude-danger: failed to launch tab" >&2; return 1; }

  # `--match` on launch/goto-layout selects a TAB, not a window, so a bare
  # `id:$first_id` (a window id) matches no tab at all. `window_id:` is the
  # tab-matcher field that resolves "the tab containing this window".
  local -i n
  for ((n = 2; n <= want; n++)); do
    kitty @ launch --match "window_id:$first_id" --cwd=current \
      -- zsh -lic "${pane_prefix}aoe session attach ${(q)titles[$n]} || exec zsh" >/dev/null
  done

  kitty @ goto-layout --match "window_id:$first_id" grid
  echo "aoe-grid-claude-danger: ${want}x claude (aoe --yolo), new tab, grid layout, titles ${label}-1..${label}-${want}"
}

# Clone the prompt repo on first run, fast-forward it on later runs.
cl4r1t4s-sync() {
  # Leaked system-prompt collection (elder-plinius/CL4R1T4S), cached under ~/.cache.
  local CL4R1T4S_REPO="${CL4R1T4S_REPO:-https://github.com/elder-plinius/CL4R1T4S.git}"
  local CL4R1T4S_DIR="${CL4R1T4S_DIR:-$HOME/.cache/CL4R1T4S}"
  command -v git >/dev/null 2>&1 || { echo "cl4r1t4s-sync: git not found on PATH" >&2; return 1; }
  if [ -d "$CL4R1T4S_DIR/.git" ]; then
    git -C "$CL4R1T4S_DIR" pull --ff-only
  else
    mkdir -p "${CL4R1T4S_DIR:h}" && git clone "$CL4R1T4S_REPO" "$CL4R1T4S_DIR"
  fi
}

# Clone PentestGPT on first run, fast-forward it on later runs.
pentestgpt-sync() {
  # Override PENTESTGPT_DIR to place the checkout elsewhere.
  local PENTESTGPT_REPO="${PENTESTGPT_REPO:-https://github.com/GreyDGL/PentestGPT.git}"
  local PENTESTGPT_DIR="${PENTESTGPT_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/PentestGPT}"
  command -v git >/dev/null 2>&1 || { echo "pentestgpt-sync: git not found on PATH" >&2; return 1; }
  if [ -d "$PENTESTGPT_DIR/.git" ]; then
    git -C "$PENTESTGPT_DIR" pull --ff-only
  else
    mkdir -p "${PENTESTGPT_DIR:h}" && git clone "$PENTESTGPT_REPO" "$PENTESTGPT_DIR"
  fi
  echo "pentestgpt-sync: $PENTESTGPT_DIR" >&2
}

# Pick a system prompt from the cache and launch claude with it (danger mode).
# Extra args pass through to claude, e.g. claude-persona -p "hi".
claude-persona() {
  local CL4R1T4S_DIR="${CL4R1T4S_DIR:-$HOME/.cache/CL4R1T4S}"
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
