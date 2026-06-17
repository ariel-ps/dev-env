# detect-msg-format — detect LLM provider format of a message (OpenAI / Anthropic / LangChain / Gemini)
#
# Usage:
#   detect-msg-format '{"role":"user","content":"hi"}'
#   echo '...' | detect-msg-format

detect-msg-format() {
  local py="$DEV_ENV_ROOT/scripts/utils/detect_message_format.py"

  if [[ ! -f "$py" ]]; then
    echo "detect-msg-format: Python script not found at $py" >&2
    return 1
  fi

  if (( $# > 0 )); then
    python3 "$py" "$@"
  elif [[ ! -t 0 ]]; then
    python3 "$py"
  else
    echo "Usage: detect-msg-format '<json message>'" >&2
    echo "       echo '<json>' | detect-msg-format" >&2
    return 1
  fi
}
