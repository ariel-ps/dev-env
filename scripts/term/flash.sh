# flash-term — flash the calling terminal's live window a color, then restore.
#
# Why the pts dance: when a helper runs under Claude Code (or any wrapper whose
# stdout is a pipe), escape codes printed to stdout never reach the real
# terminal. So we identify the GUI terminal + its pts by walking the process
# ancestry, then write OSC 11 (set background) / OSC 111 (reset background)
# straight to that pts. Works on kitty, iTerm2, WezTerm, ghostty, xterm.
#
# Everything below avoids top-level vars/arrays and single-underscore helper
# names on purpose: Claude Code's Bash tool runs off a shell *snapshot* that
# only replays function bodies, and it drops anything named like a zsh
# completion function (single leading underscore, e.g. `_flash_identify`) plus
# any `typeset -gA` array state. Under that snapshot the old array-based
# version failed silently — sound played, flash never fired, no error shown.
#
# usage: flash-term [color] [flashes] [interval_sec]
#   color     hex like '#00cc44' (default) or a name: green/blue/red/white/
#             yellow/orange/purple/cyan
#   flashes   number of on/off cycles (default 4)
#   interval  seconds per half-cycle (default 0.13)
#   e.g. flash-term                 # green x4
#        flash-term blue            # blue x4
#        flash-term '#ff0000' 6 0.1 # fast red x6

# name -> hex. Case statement, not typeset -gA, so it survives the snapshot.
__flash_color_hex() {
  case "$1" in
    green)  print -r -- '#00cc44' ;;
    blue)   print -r -- '#1e66ff' ;;
    red)    print -r -- '#ff0000' ;;
    white)  print -r -- '#ffffff' ;;
    yellow) print -r -- '#ffd000' ;;
    orange) print -r -- '#ff8800' ;;
    purple) print -r -- '#a020f0' ;;
    cyan)   print -r -- '#00e5e5' ;;
    *)      print -r -- "$1" ;;
  esac
}

# Walk up from a pid until we find a process on a real tty (not "??"), and note
# the GUI terminal emulator name along the way. Prints "<pts>\t<emu>".
__flash_identify() {
  local p="${1:-$PPID}" ppid t comm tty="" emu="" i
  for i in {1..20}; do
    IFS=' ' read -r ppid t comm <<<"$(ps -o ppid=,tty=,comm= -p "$p" 2>/dev/null)"
    [[ -z "$ppid" ]] && break
    [[ -z "$tty" && -n "$t" && "$t" != "??" ]] && tty="/dev/$t"
    case "$comm" in
      (*kitty*)              emu="kitty"; break ;;
      (*iTerm*)              emu="iterm2"; break ;;
      (*WezTerm*|*wezterm*)  emu="wezterm"; break ;;
      (*alacritty*)          emu="alacritty"; break ;;
      (*ghostty*|*Ghostty*)  emu="ghostty"; break ;;
      (*Terminal*)           emu="apple-terminal"; break ;;
      (*login*|*zsh*|*bash*|*claude*|*node*|*tmux*|*perl*) ;;
      (*) [[ -n "$comm" ]] && emu="${comm:t}" ;;
    esac
    p="$ppid"
  done
  # env fallback if ancestry was inconclusive
  if [[ -z "$emu" ]]; then
    if [[ -n "$KITTY_PID" ]]; then emu="kitty"
    elif [[ "$TERM_PROGRAM" == "iTerm.app" ]]; then emu="iterm2"
    elif [[ "$TERM_PROGRAM" == "Apple_Terminal" ]]; then emu="apple-terminal"
    elif [[ -n "$WEZTERM_PANE" ]]; then emu="wezterm"
    else emu="unknown(${TERM})"; fi
  fi
  print -r -- "${tty}"$'\t'"${emu}"
}

# Current background of the kitty window this process runs in, as #rrggbb.
# Prints nothing when that can't be determined (not kitty, no remote control,
# no matching window) — the caller then falls back to OSC 111.
#
# Why this exists: OSC 111 resets the background to the one in kitty.conf, not
# to whatever the window is actually showing. kitty-colorize-panes assigns each
# pane its own theme live via `kitty @ set-colors`, so flashing used to leave
# every pane it touched reverted to the default background. Restoring this
# exact value instead keeps the pane's theme.
__flash_kitty_bg() {
  command -v kitty >/dev/null 2>&1 || return 0
  # Ancestry as a plain space-separated string, not an array: the Bash-tool
  # shell snapshot drops array state (see the header comment).
  local pids="" p="${1:-$PPID}" ppid i
  for i in {1..20}; do
    pids="$pids $p"
    ppid="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    [[ -z "$ppid" || "$ppid" == 0 || "$ppid" == 1 ]] && break
    p="$ppid"
  done

  local wid
  wid="$(kitty @ ls 2>/dev/null | python3 -c '
import json, sys
pids = {int(x) for x in sys.argv[1].split()}
for osw in json.load(sys.stdin):
    for tab in osw["tabs"]:
        for w in tab["windows"]:
            here = {w.get("pid")} | {p.get("pid") for p in w.get("foreground_processes", [])}
            if here & pids:
                print(w["id"])
                raise SystemExit
' "$pids" 2>/dev/null)" || return 0
  [[ -n "$wid" ]] || return 0

  kitty @ get-colors --match "id:$wid" 2>/dev/null \
    | awk '$1 == "background" { print $2; exit }'
}

flash-term() {
  local color="${1:-green}" flashes="${2:-4}" iv="${3:-0.13}"
  color="$(__flash_color_hex "$color")"
  [[ "$color" == \#* ]] \
    || { echo "flash-term: color must be a name or #rrggbb, got: $color" >&2; return 1; }

  local ident tty emu
  ident="$(__flash_identify "$PPID")"
  tty="${ident%%$'\t'*}"; emu="${ident##*$'\t'}"
  [[ -n "$tty" ]] \
    || { echo "flash-term: no pts found in process ancestry" >&2; return 1; }
  command -v perl >/dev/null 2>&1 \
    || { echo "flash-term: perl not found" >&2; return 1; }

  # Restore to the window's real current background when we can read it, so a
  # flash doesn't wipe a per-pane theme; OSC 111 only as the fallback.
  local restore=""
  [[ "$emu" == kitty ]] && restore="$(__flash_kitty_bg "$PPID")"

  echo "flash-term: $emu on $tty ($color x$flashes${restore:+, restore $restore})"
  perl -e '
    open(T,">",$ARGV[0]) or die "open $ARGV[0]: $!";
    select((select(T),$|=1)[0]);
    my $set   = "\e]11;$ARGV[1]\e\\";
    my $reset = $ARGV[4] ne "" ? "\e]11;$ARGV[4]\e\\" : "\e]111\e\\";
    for(1..$ARGV[2]){print T $set;   select(undef,undef,undef,$ARGV[3]);
                     print T $reset; select(undef,undef,undef,$ARGV[3]);}
    print T $reset; close T;
  ' "$tty" "$color" "$flashes" "$iv" "$restore"
}

# ---------------------------------------------------------------------------
# pflash — mood-driven combo: flash a mood-matched color AND play the matching
# 8-bit `psound` (from the alert profile), overlapping. One call to signal a
# meaningful moment both visually and audibly.
#
# usage: pflash <mood> [volume|preset]
#   pflash --list          # show moods
#   e.g. pflash done ; pflash error loud ; pflash coin quiet
# Sound needs the alert profile + cached mario clips (`alert8-sync mario`);
# if psound is missing the flash still runs.
# ---------------------------------------------------------------------------

# mood -> flash color name, empty on unknown mood (caller decides the
# fallback). Single source of the mood->color map; the alert profile's sound
# functions call it (guarded) so their flashes match the mood being signalled.
__flash_mood_color() {
  case "${1:-}" in
    done|win|complete|success|bigwin|shipped|merged) print -r -- green ;;
    coin|progress|step)                               print -r -- cyan ;;
    powerup|installed|upgrade|start|go|build)         print -r -- blue ;;
    error|fail|broke)                                 print -r -- red ;;
    fatal|gameover|abort)                             print -r -- purple ;;
    warn|careful)                                     print -r -- orange ;;
    waiting|thinking)                                 print -r -- yellow ;;
  esac
}

# pflash is now just sugar: psound already flashes (see alert profile), so this
# plays the mood sound + flash together. Falls back to a bare flash if the alert
# profile isn't loaded.
pflash() {
  if [[ "${1:-}" == "--list" || $# -eq 0 ]]; then
    print -r -- "pflash moods: done win complete success bigwin shipped merged coin progress step powerup installed upgrade start go build error fail broke fatal gameover abort warn careful waiting thinking"
    return 0
  fi
  local mood="$1"; shift
  if typeset -f psound >/dev/null 2>&1; then
    psound "$mood" "$@"
  else
    local color
    color="$(__flash_mood_color "$mood")"
    flash-term "${color:-white}"
  fi
}

# zsh completion: named colors for flash-term, moods for pflash.
if [[ -n "$ZSH_VERSION" ]]; then
  __flash_term_complete() { compadd green blue red white yellow orange purple cyan; }
  compdef __flash_term_complete flash-term 2>/dev/null
  __pflash_complete() { compadd done win complete success bigwin shipped merged coin progress step powerup installed upgrade start go build error fail broke fatal gameover abort warn careful waiting thinking; }
  compdef __pflash_complete pflash 2>/dev/null
fi
