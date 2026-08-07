#!/usr/bin/env zsh
# cx — cross-Claude session comms. Give each Claude Code session running in a
# kitty pane a stable slot number + name, so one Claude can be told to message,
# read, or focus another:
#
#   cx ls                        # roster: slot, name, kitty win, live status
#   cx send 3 "rebase onto main" # type into pane 3 and submit
#   cx peek 3 60                 # read pane 3's last 60 lines
#   cx focus 3 ; cx name 3 thesis ; cx me
#
# Named `cx`, not `cc`: /usr/bin/cc is the C compiler and shadowing it breaks
# every build in the shell. `claudes` is a long alias for the same thing.
#
# The real work is in bin/cx.py (kitty remote control + the pane registry);
# these wrappers exist so the commands are on PATH for interactive use, for
# Claude Code's Bash tool, and for the SessionStart hook.
#
# Requires: kitty remote control (`allow_remote_control yes` in kitty.conf) and
# running inside kitty. State lives in ${CX_STATE_DIR:-~/.claude/cx}/panes/.

# Adds scripts/cx/bin to PATH so `cx` also works as a plain executable — needed
# wherever these functions aren't loaded (subshells, sh, a Claude Bash tool call
# whose shell snapshot dropped them).
_CX_BIN_DIR="${0:A:h}/bin"
if [[ -d "$_CX_BIN_DIR" && ":$PATH:" != *":$_CX_BIN_DIR:"* ]]; then
  path=("$_CX_BIN_DIR" $path)
fi
unset _CX_BIN_DIR

__cx_py() { print -r -- "${DEV_ENV_ROOT:-$HOME/Documents/projects/dev-env}/scripts/cx/bin/cx.py" }

# Absolute interpreter paths on purpose. Inside a Claude Code session PATH
# starts with the modern-python plugin's shim dir, whose `python3` refuses to
# run and prints "Use `uv run python ...` instead" — which would break cx for
# its main caller. cx.py is stdlib-only, so any of these work.
__cx_python() {
  local p
  for p in /opt/homebrew/bin/python3 /usr/bin/python3; do
    [[ -x "$p" ]] && { print -r -- "$p"; return 0 }
  done
  command -v python3 2>/dev/null
}

cx() {
  emulate -L zsh
  local py python
  py="$(__cx_py)"
  [[ -r "$py" ]] || { echo "cx: helper missing at $py" >&2; return 1 }
  python="$(__cx_python)"
  [[ -n "$python" ]] || { echo "cx: no python3 found" >&2; return 1 }
  "$python" "$py" "$@"
}

# Long-form alias, for when `cx` is too cryptic to read back in a script.
claudes() { cx "$@" }

# cx-register / cx-unregister — SessionStart / SessionEnd hook entry points.
# Both swallow every failure: a broken registry must never stop a Claude
# session from starting. Wire them up with cx-install-hooks.
cx-register()   { cx register   2>/dev/null; return 0 }
cx-unregister() { cx unregister 2>/dev/null; return 0 }

# cx-install-hooks — add the SessionStart/SessionEnd hooks to
# ~/.claude/settings.json so every new Claude session self-registers: claiming a
# slot and naming itself after its cwd. Pane *titles* are left alone, since
# kitty-agent-title already owns them. Idempotent, and backs the file up first.
# Only affects sessions started afterwards; panes already open stay `~`.
#
# Without the hooks, `cx ls` still works — panes are discovered from kitty's
# process table and marked `~` — they just have no Claude session id and get
# slot numbers that can shift as panes come and go.
cx-install-hooks() {
  emulate -L zsh
  local settings="$HOME/.claude/settings.json"
  local py python
  py="$(__cx_py)"; python="$(__cx_python)"
  [[ -r "$settings" ]] || { echo "cx-install-hooks: $settings not found" >&2; return 1 }
  [[ -r "$py" ]] || { echo "cx-install-hooks: helper missing at $py" >&2; return 1 }
  [[ -n "$python" ]] || { echo "cx-install-hooks: no python3 found" >&2; return 1 }

  cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)" || return 1

  "$python" - "$settings" "$py" "$python" <<'PY'
import json, sys

settings_path, helper, python = sys.argv[1], sys.argv[2], sys.argv[3]
with open(settings_path) as fh:
    cfg = json.load(fh)

hooks = cfg.setdefault("hooks", {})
# Absolute interpreter: hooks inherit the session PATH, which starts with the
# modern-python shim whose python3 refuses to run.
# `exit 0` at the end of each: hook failure must not block the session.
wanted = {
    "SessionStart": f"{python} {helper} register 2>/dev/null; exit 0 # cx-hooks",
    "SessionEnd": f"{python} {helper} unregister 2>/dev/null; exit 0 # cx-hooks",
}
changed = []
for event, command in wanted.items():
    groups = hooks.setdefault(event, [])
    existing = [
        h
        for g in groups
        for h in g.get("hooks", [])
        if "cx-hooks" in h.get("command", "")
    ]
    if existing:
        for h in existing:
            if h["command"] != command:
                h["command"] = command
                changed.append(f"{event} (updated)")
        continue
    groups.append({"hooks": [{"type": "command", "command": command}]})
    changed.append(event)

with open(settings_path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")

print("cx-install-hooks: " + (", ".join(changed) if changed else "already installed"))
PY
}

# cx-uninstall-hooks — remove the cx hooks from ~/.claude/settings.json,
# leaving every other hook untouched.
cx-uninstall-hooks() {
  emulate -L zsh
  local settings="$HOME/.claude/settings.json" python
  python="$(__cx_python)"
  [[ -r "$settings" ]] || { echo "cx-uninstall-hooks: $settings not found" >&2; return 1 }
  [[ -n "$python" ]] || { echo "cx-uninstall-hooks: no python3 found" >&2; return 1 }
  cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)" || return 1
  "$python" - "$settings" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as fh:
    cfg = json.load(fh)

removed = 0
for event, groups in list(cfg.get("hooks", {}).items()):
    for group in groups:
        before = len(group.get("hooks", []))
        group["hooks"] = [h for h in group.get("hooks", []) if "cx-hooks" not in h.get("command", "")]
        removed += before - len(group["hooks"])
    cfg["hooks"][event] = [g for g in groups if g.get("hooks")]
    if not cfg["hooks"][event]:
        del cfg["hooks"][event]

with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
    fh.write("\n")
print(f"cx-uninstall-hooks: removed {removed} hook(s)")
PY
}

# zsh completion: subcommands, then live slot:name targets from the roster.
# Gated on compdef actually existing (compinit has run): in a non-interactive
# zsh it does not, and a bare `compdef` would make sourcing this file exit 127.
if [[ -n "$ZSH_VERSION" ]] && (( $+functions[compdef] )); then
  __cx_complete() {
    local -a subs
    subs=(ls send bcast peek focus name me gc register unregister help)
    if (( CURRENT == 2 )); then
      compadd -- $subs
      return
    fi
    case "${words[2]}" in
      send|peek|focus|name|read|msg|tell|go|rename)
        local -a targets
        targets=("${(@f)$(cx ls -q 2>/dev/null | awk -F'\t' '{print $1; print $2}')}")
        compadd -- ${targets:#} ;;
    esac
  }
  compdef __cx_complete cx 2>/dev/null
  compdef __cx_complete claudes 2>/dev/null
fi
