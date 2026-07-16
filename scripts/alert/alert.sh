#!/usr/bin/env zsh
# Gilfoyle-style alert — sourced by init.zsh
#
# Plays Napalm Death's "You Suffer" (the Bitcoin-crash alert from Silicon
# Valley S5E03). Handy as an audible "done"/"broke" signal for long tasks.

_ALERT_DIR="${0:A:h}"
_ALERT_BIN_DIR="$_ALERT_DIR/bin"

_alert_random_id() {
  local id
  if command -v od >/dev/null 2>&1; then
    id="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  [[ -n "$id" ]] && { print -r -- "$id"; return; }
  printf '%04x%04x%04x%04x\n' "$RANDOM" "$RANDOM" "$RANDOM" "$RANDOM"
}

_alert8_generate_session_sound() {
  local sound="${1:-$ALERT8_SESSION_SOUND}"
  local generator="$_ALERT_BIN_DIR/generate-8bit-alert.py"
  [[ -n "$sound" ]] || return 1
  [[ -r "$generator" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  mkdir -p "${sound:h}" || return 1
  python3 "$generator" "$sound" --seed "$ALERT_SESSION_ID"
}

_ALERT_TMP_DIR="${TMPDIR:-/tmp}"
_ALERT_TMP_DIR="${_ALERT_TMP_DIR%/}"
[[ -n "${ALERT_SESSION_ID:-}" ]] || ALERT_SESSION_ID="$(_alert_random_id)"
[[ -n "${ALERT8_SESSION_SOUND:-}" ]] || ALERT8_SESSION_SOUND="$_ALERT_TMP_DIR/dev-env-alert/${ALERT_SESSION_ID}-8bit-alert.wav"
[[ -r "$ALERT8_SESSION_SOUND" ]] || _alert8_generate_session_sound "$ALERT8_SESSION_SOUND" >/dev/null 2>&1
unset _ALERT_TMP_DIR

: "${GILFOYLE_VOLUME:=1.8}"
: "${ALERT8_VOLUME:=1.0}"

_alert_resolve_volume() {
  local requested="${1:-}"
  local default_volume="${2:-1.0}"
  local volume
  case "$requested" in
    ""|default) volume="$default_volume" ;;
    calm|quiet) volume="0.4" ;;
    normal) volume="1.0" ;;
    loud) volume="1.8" ;;
    louder) volume="2.5" ;;
    max) volume="3.0" ;;
    *) volume="$requested" ;;
  esac
  [[ "$volume" =~ '^([0-9]+([.][0-9]+)?|[.][0-9]+)$' ]] || return 1
  print -r -- "$volume"
}

# usage: gilfoyle [volume|preset]
#   default volume comes from GILFOYLE_VOLUME and defaults to 1.8
#   presets: calm/quiet=0.4, normal=1.0, loud=1.8, louder=2.5, max=3.0
#   e.g. long-build; gilfoyle          # notify loudly
#        gilfoyle louder               # very loud Gilfoyle
#        gilfoyle 1.0                  # full original volume
gilfoyle() {
  local vol
  vol="$(_alert_resolve_volume "${1:-}" "$GILFOYLE_VOLUME")" \
    || { echo "gilfoyle: invalid volume or preset: ${1:-$GILFOYLE_VOLUME}" >&2; return 1; }
  local sound="$_ALERT_DIR/gilfoyle-alert.mp3"
  command -v afplay >/dev/null 2>&1 \
    || { echo "gilfoyle: afplay not found (macOS only)" >&2; return 1; }
  [[ -r "$sound" ]] \
    || { echo "gilfoyle: sound not found: $sound" >&2; return 1; }
  afplay -v "$vol" "$sound"
}

# Play a short 8-bit pickup-style alert.
# usage: alert8 [volume|preset]
#   default volume comes from ALERT8_VOLUME and defaults to 1.0
#   presets: calm/quiet=0.4, normal=1.0, loud=1.8, louder=2.5, max=3.0
alert8() {
  local vol
  vol="$(_alert_resolve_volume "${1:-}" "$ALERT8_VOLUME")" \
    || { echo "alert8: invalid volume or preset: ${1:-$ALERT8_VOLUME}" >&2; return 1; }
  local sound="${ALERT8_SESSION_SOUND:-}"
  if [[ -z "$sound" || ! -r "$sound" ]]; then
    _alert8_generate_session_sound "$sound" >/dev/null 2>&1
  fi
  [[ -r "$sound" ]] || sound="$_ALERT_DIR/8bit-alert.wav"
  command -v afplay >/dev/null 2>&1 \
    || { echo "alert8: afplay not found (macOS only)" >&2; return 1; }
  [[ -r "$sound" ]] \
    || { echo "alert8: sound not found: $sound" >&2; return 1; }
  afplay -v "$vol" "$sound"
}

# ---------------------------------------------------------------------------
# alert8play — random real 8-bit game sound, chosen by the current "session
# type" (which dev-env profile / project the shell is in).
#
# Sounds are NOT bundled in the repo. Run `alert8-sync` once to download game
# sound packs from archive.org into the cache dir below. `alert8play` then
# detects the profile from $PWD (git repo name or path), maps it to a game, and
# plays a random clip from that game's cache folder.
# ---------------------------------------------------------------------------

_ALERT8_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dev-env-alert/sounds"

# game key -> archive.org identifier (verified downloadable sound-effect items)
typeset -gA _ALERT8_GAMES
_ALERT8_GAMES=(
  mario     mario_nes_snes_sounds
  mvdk      131_20220817
  punchout  nes-punch-out-mike-tysons-punch-out-sound-effects_sounds-resource-mirror-30jul2024-01
  metalgear sound-effect-44
  sonic     sa-2-288
  kirby     KirbyNIDL
)

# dev-env profile / project -> game key. "default" is the fallback.
typeset -gA _ALERT8_PROFILE_GAME
_ALERT8_PROFILE_GAME=(
  ps-agent    mario
  ps-platform mvdk
  aws-vpn     metalgear
  k8s         sonic
  docker      kirby
  git         punchout
  dev-env     mario
  default     mario
)

# Detect the current session's profile from the working directory. Uses the git
# repo name when inside one, else the cwd basename. Prints a profile key that is
# a valid index into _ALERT8_PROFILE_GAME (falls back to "default").
_alert8_detect_profile() {
  local top name
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top="$PWD"
  name="${top:t:l}"   # basename, lowercased
  case "$name" in
    *mac-guard*|*ps-agent*)        print -r -- ps-agent ;;
    *ps-platform*|*ps-frontend*)   print -r -- ps-platform ;;
    *aws-vpn*|*vpn*)               print -r -- aws-vpn ;;
    *dev-env*)                     print -r -- dev-env ;;
    *k8s*|*kube*)                  print -r -- k8s ;;
    *docker*)                      print -r -- docker ;;
    *)
      # Path keyword fallback for repos that don't match by name.
      case ":$PWD:" in
        *:*/k8s/*:*|*kube*) print -r -- k8s ;;
        *docker*)           print -r -- docker ;;
        *)                  print -r -- default ;;
      esac
      ;;
  esac
}

# Resolve the game key for a profile, defaulting when unmapped.
_alert8_game_for_profile() {
  local profile="${1:-default}"
  local game="${_ALERT8_PROFILE_GAME[$profile]:-${_ALERT8_PROFILE_GAME[default]}}"
  print -r -- "$game"
}

# Download all mapped game sound packs into the cache. Safe to re-run; already
# downloaded files are skipped. usage: alert8-sync [game ...]
alert8-sync() {
  local fetch="$_ALERT_BIN_DIR/fetch-game-sounds.py"
  command -v python3 >/dev/null 2>&1 \
    || { echo "alert8-sync: python3 not found" >&2; return 1; }
  [[ -r "$fetch" ]] \
    || { echo "alert8-sync: fetcher missing: $fetch" >&2; return 1; }

  local -a games
  if (( $# )); then
    games=("$@")
  else
    games=(${(k)_ALERT8_GAMES})
  fi

  local game id rc=0
  for game in $games; do
    id="${_ALERT8_GAMES[$game]:-}"
    if [[ -z "$id" ]]; then
      echo "alert8-sync: unknown game '$game' (known: ${(k)_ALERT8_GAMES})" >&2
      rc=1; continue
    fi
    echo "alert8-sync: $game ($id) ..." >&2
    python3 "$fetch" "$id" "$_ALERT8_CACHE_DIR/$game" || rc=1
  done
  return $rc
}

# Play a random 8-bit clip for the current profile's game.
# usage: alert8play [volume|preset]
#   presets: calm/quiet=0.4, normal=1.0, loud=1.8, louder=2.5, max=3.0
#   Detects profile from $PWD; run `alert8-sync` first to populate the cache.
alert8play() {
  local vol
  vol="$(_alert_resolve_volume "${1:-}" "$ALERT8_VOLUME")" \
    || { echo "alert8play: invalid volume or preset: ${1:-$ALERT8_VOLUME}" >&2; return 1; }
  command -v afplay >/dev/null 2>&1 \
    || { echo "alert8play: afplay not found (macOS only)" >&2; return 1; }

  local profile game dir
  profile="$(_alert8_detect_profile)"
  game="$(_alert8_game_for_profile "$profile")"
  dir="$_ALERT8_CACHE_DIR/$game"

  local -a clips
  clips=("$dir"/*.(wav|mp3|ogg)(N.))
  if (( ${#clips} == 0 )); then
    # Fall back to any populated game, then to the per-session procedural sound.
    local other
    for other in ${(k)_ALERT8_GAMES}; do
      clips=("$_ALERT8_CACHE_DIR/$other"/*.(wav|mp3|ogg)(N.))
      (( ${#clips} )) && break
    done
  fi
  if (( ${#clips} == 0 )); then
    echo "alert8play: no cached sounds — run 'alert8-sync' first" >&2
    alert8 "$vol"   # procedural fallback
    return
  fi

  local pick="${clips[$(( RANDOM % ${#clips} + 1 ))]}"
  # Cap duration so a long music track can't turn a "done" alert into a
  # 30-second block. Override with ALERT8_MAX_SECONDS (empty = play in full).
  local -a cap
  [[ -n "${ALERT8_MAX_SECONDS-3}" ]] && cap=(-t "${ALERT8_MAX_SECONDS:-3}")
  afplay -v "$vol" $cap "$pick"
}

# ---------------------------------------------------------------------------
# psound — semantic 8-bit cue. Pick a mood that matches what just happened and
# it plays the fitting Mario clip. Meant to be called by tooling/agents at
# meaningful moments (task done, error, milestone) rather than by project.
#
# Sounds come from the `mario` game cache (well-named clips). Populate with
# `alert8-sync mario` (or copy the local Mario set into the mario cache dir).
# ---------------------------------------------------------------------------

: "${ALERT8_MOOD_GAME:=mario}"

# mood keyword -> clip basename (without extension) in the mood game's cache.
# Several synonyms map to the same clip so callers can use natural words.
typeset -gA _ALERT8_MOODS
_ALERT8_MOODS=(
  done       'Mario 1 - Win Stage'
  win        'Mario 1 - Win Stage'
  complete   'Mario 1 - Win Stage'
  success    '1up'
  bigwin     '1up'
  shipped    '1up'
  merged     '1up'
  coin       'coin (nes)'
  progress   'coin (nes)'
  step       'coin (nes)'
  powerup    'Power Up (nes)'
  installed  'Power Up (nes)'
  upgrade    'Power Up (nes)'
  start      'Mario 1 - Jump'
  go         'Mario 1 - Jump'
  build      'Mario 1 - Jump'
  error      'Mario 1 - Die'
  fail       'Mario 1 - Die'
  broke      'Mario 1 - Die'
  fatal      'Mario 1 - Game Over'
  gameover   'Mario 1 - Game Over'
  abort      'Mario 1 - Game Over'
  warn       "time's running out"
  careful    "time's running out"
  waiting    'Break Brick'
  thinking   'Break Brick'
)

# usage: psound <mood> [volume|preset]
#   psound --list   # show available moods
#   e.g. psound done ; psound error loud ; psound coin quiet
psound() {
  if [[ "${1:-}" == "--list" || $# -eq 0 ]]; then
    print -r -- "psound moods: ${(ko)_ALERT8_MOODS}"
    return 0
  fi
  local mood="$1"; shift
  local base="${_ALERT8_MOODS[$mood]:-}"
  [[ -n "$base" ]] \
    || { echo "psound: unknown mood '$mood' (see: psound --list)" >&2; return 1; }

  local vol
  vol="$(_alert_resolve_volume "${1:-}" "$ALERT8_VOLUME")" \
    || { echo "psound: invalid volume or preset: ${1}" >&2; return 1; }
  command -v afplay >/dev/null 2>&1 \
    || { echo "psound: afplay not found (macOS only)" >&2; return 1; }

  local dir="$_ALERT8_CACHE_DIR/$ALERT8_MOOD_GAME"
  local -a hit
  hit=("$dir/$base".(wav|mp3|ogg)(N.))
  if (( ${#hit} == 0 )); then
    echo "psound: clip '$base' not cached — run 'alert8-sync $ALERT8_MOOD_GAME'" >&2
    return 1
  fi
  local -a cap
  [[ -n "${ALERT8_MAX_SECONDS-3}" ]] && cap=(-t "${ALERT8_MAX_SECONDS:-3}")
  afplay -v "$vol" $cap "${hit[1]}"
}

# Find the bundle id of the running GUI terminal (we may be inside tmux, so
# $TERM_PROGRAM is unreliable). Prints e.g. com.apple.Terminal, or nothing.
_alert8_terminal_bundle() {
  local app bid
  for app in iTerm iTerm2 Terminal Ghostty WezTerm kitty Alacritty Warp Hyper; do
    bid="$(osascript -e "id of app \"$app\"" 2>/dev/null)" || continue
    [[ -n "$bid" ]] || continue
    pgrep -qf "$app" 2>/dev/null && { print -r -- "$bid"; return 0; }
  done
  return 1
}

# pnotify — macOS notification banner + matching 8-bit mood sound.
# usage: pnotify <mood> <message> [title]
#   title defaults to "Claude"; mood drives both banner tone and the sound.
#   Clicking the banner focuses the terminal and, if inside tmux, switches that
#   client back to the session that fired the notification.
#   e.g. pnotify done "build finished" ; pnotify error "tests failed"
# Note: first use may be silent until the terminal app (or "terminal-notifier")
# is granted notification permission in System Settings > Notifications, and
# Focus/Do-Not-Disturb is off.
pnotify() {
  local mood="${1:-done}" message="${2:-}" title="${3:-Claude}"
  [[ -n "$message" ]] \
    || { echo "pnotify: usage: pnotify <mood> <message> [title]" >&2; return 1; }
  # Prefer terminal-notifier: works through tmux/ssh, registers its own app in
  # System Settings > Notifications, and is more reliable than osascript.
  if command -v terminal-notifier >/dev/null 2>&1; then
    local -a click
    local bid session
    bid="$(_alert8_terminal_bundle)"
    session="$(tmux display-message -p '#S' 2>/dev/null)"
    if [[ -n "$bid" ]]; then
      if [[ -n "$session" ]]; then
        # Focus terminal, then point the attached tmux client at this session.
        click=(-execute "osascript -e 'tell application id \"$bid\" to activate'; tmux switch-client -t '$session' 2>/dev/null")
      else
        click=(-activate "$bid")
      fi
    fi
    terminal-notifier -title "$title" -message "$message" \
      -group "dev-env-alert" "${click[@]}" >/dev/null 2>&1
  elif command -v osascript >/dev/null 2>&1; then
    # Escape double quotes so AppleScript string literals stay well-formed.
    local m="${message//\"/\\\"}" t="${title//\"/\\\"}"
    osascript -e "display notification \"$m\" with title \"$t\"" 2>/dev/null
  fi
  psound "$mood" 2>/dev/null
}

# zsh completion.
if [[ -n "$ZSH_VERSION" ]]; then
  _alert8_sync_complete() { compadd ${(k)_ALERT8_GAMES}; }
  compdef _alert8_sync_complete alert8-sync 2>/dev/null
  _psound_complete() { compadd ${(k)_ALERT8_MOODS}; }
  compdef _psound_complete psound 2>/dev/null
  compdef _psound_complete pnotify 2>/dev/null
fi

# Speak a short "task done" summary via macOS text-to-speech.
# usage: psay <text ...>
#   rate:  say's native default; set PSAY_RATE (words/min) to override
#   voice: override with PSAY_VOICE (see `say -v '?'` for the list)
#   e.g. psay "backend deployed to ariel-ps"
#        PSAY_RATE=300 psay "build finished"
#        PSAY_VOICE=Daniel psay "done"
psay() {
  [[ $# -gt 0 ]] || { echo "psay: nothing to say" >&2; return 1; }
  command -v say >/dev/null 2>&1 \
    || { echo "psay: say not found (macOS only)" >&2; return 1; }
  local args=()
  [[ -n "$PSAY_RATE" ]]  && args+=(-r "$PSAY_RATE")
  [[ -n "$PSAY_VOICE" ]] && args+=(-v "$PSAY_VOICE")
  say "${args[@]}" -- "$*"
}
