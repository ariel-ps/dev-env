# mitm-to-jsonl — convert mitmproxy capture files (.mitm / .flow) to JSONL
#
# Usage:
#   mitm-to-jsonl capture.mitm
#   mitm-to-jsonl capture.mitm -o out.jsonl
#   mitm-to-jsonl a.mitm b.mitm -o combined.jsonl
#   cat capture.mitm | mitm-to-jsonl -

mitm-to-jsonl() {
  local py="$DEV_ENV_ROOT/scripts/utils/mitm_to_jsonl.py"

  # resolve the Python that ships with mitmproxy
  local mitmdump_bin
  mitmdump_bin=$(command -v mitmdump 2>/dev/null)
  if [[ -z "$mitmdump_bin" ]]; then
    echo "mitm-to-jsonl: mitmdump not found on PATH" >&2
    return 1
  fi
  local mitm_python
  mitm_python=$(head -1 "$mitmdump_bin" | sed 's/^#!//')

  if [[ ! -x "$mitm_python" ]]; then
    echo "mitm-to-jsonl: could not resolve mitmproxy Python at $mitm_python" >&2
    return 1
  fi

  if (( $# == 0 )) && [[ -t 0 ]]; then
    echo "Usage: mitm-to-jsonl <file.mitm> [-o out.jsonl]" >&2
    echo "       cat capture.mitm | mitm-to-jsonl -" >&2
    return 1
  fi

  "$mitm_python" "$py" "$@"
}

_mitm_to_jsonl() {
  local state context
  _arguments \
    '-o[output file]:file:_files' \
    '*:mitmproxy capture file:_files -g "*.mitm *.flow"'
}
compdef _mitm_to_jsonl mitm-to-jsonl
