# flash-term — flash the calling terminal's live window a color, then restore.
#
# Why the pts dance: when a helper runs under Claude Code (or any wrapper whose
# stdout is a pipe), escape codes printed to stdout never reach the real
# terminal. So we identify the GUI terminal + its pts by walking the process
# ancestry, then write OSC 11 (set background) / OSC 111 (reset background)
# straight to that pts. Works on kitty, iTerm2, WezTerm, ghostty, xterm.
#
# usage: flash-term [color] [flashes] [interval_sec]
#   color     hex like '#00cc44' (default) or a name: green/blue/red/white/
#             yellow/orange/purple/cyan
#   flashes   number of on/off cycles (default 4)
#   interval  seconds per half-cycle (default 0.13)
#   e.g. flash-term                 # green x4
#        flash-term blue            # blue x4
#        flash-term '#ff0000' 6 0.1 # fast red x6

typeset -gA _FLASH_COLORS
_FLASH_COLORS=(
  green  '#00cc44'
  blue   '#1e66ff'
  red    '#ff0000'
  white  '#ffffff'
  yellow '#ffd000'
  orange '#ff8800'
  purple '#a020f0'
  cyan   '#00e5e5'
)

# Walk up from a pid until we find a process on a real tty (not "??"), and note
# the GUI terminal emulator name along the way. Prints "<pts>\t<emu>".
_flash_identify() {
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

flash-term() {
  local color="${1:-green}" flashes="${2:-4}" iv="${3:-0.13}"
  # resolve a named color to hex
  [[ -n "${_FLASH_COLORS[$color]:-}" ]] && color="${_FLASH_COLORS[$color]}"
  [[ "$color" == \#* ]] \
    || { echo "flash-term: color must be a name or #rrggbb, got: $color" >&2; return 1; }

  local ident tty emu
  ident="$(_flash_identify "$PPID")"
  tty="${ident%%$'\t'*}"; emu="${ident##*$'\t'}"
  [[ -n "$tty" ]] \
    || { echo "flash-term: no pts found in process ancestry" >&2; return 1; }
  command -v perl >/dev/null 2>&1 \
    || { echo "flash-term: perl not found" >&2; return 1; }

  echo "flash-term: $emu on $tty ($color x$flashes)"
  perl -e '
    open(T,">",$ARGV[0]) or die "open $ARGV[0]: $!";
    select((select(T),$|=1)[0]);
    my ($set,$reset)=("\e]11;$ARGV[1]\e\\","\e]111\e\\");
    for(1..$ARGV[2]){print T $set;   select(undef,undef,undef,$ARGV[3]);
                     print T $reset; select(undef,undef,undef,$ARGV[3]);}
    print T $reset; close T;
  ' "$tty" "$color" "$flashes" "$iv"
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
typeset -gA _FLASH_MOOD_COLOR
_FLASH_MOOD_COLOR=(
  done green  win green  complete green  success green
  bigwin green  shipped green  merged green
  coin cyan  progress cyan  step cyan
  powerup blue  installed blue  upgrade blue
  start blue  go blue  build blue
  error red  fail red  broke red
  fatal purple  gameover purple  abort purple
  warn orange  careful orange
  waiting yellow  thinking yellow
)

# Resolve a mood keyword to its flash color (falls back to white). This is the
# single source of the mood→color map; the alert profile's sound functions call
# it (guarded) so their flashes match the mood being signalled.
_flash_mood_color() {
  print -r -- "${_FLASH_MOOD_COLOR[${1:-done}]:-white}"
}

# pflash is now just sugar: psound already flashes (see alert profile), so this
# plays the mood sound + flash together. Falls back to a bare flash if the alert
# profile isn't loaded.
pflash() {
  if [[ "${1:-}" == "--list" || $# -eq 0 ]]; then
    print -r -- "pflash moods: ${(ko)_FLASH_MOOD_COLOR}"
    return 0
  fi
  local mood="$1"; shift
  if typeset -f psound >/dev/null 2>&1; then
    psound "$mood" "$@"
  else
    flash-term "$(_flash_mood_color "$mood")"
  fi
}

# zsh completion: named colors for flash-term, moods for pflash.
if [[ -n "$ZSH_VERSION" ]]; then
  _flash_term_complete() { compadd ${(k)_FLASH_COLORS}; }
  compdef _flash_term_complete flash-term 2>/dev/null
  _pflash_complete() { compadd ${(k)_FLASH_MOOD_COLOR}; }
  compdef _pflash_complete pflash 2>/dev/null
fi
