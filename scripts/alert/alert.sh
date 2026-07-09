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
