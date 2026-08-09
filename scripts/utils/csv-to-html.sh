# csv2html — view a CSV as a self-contained interactive HTML table
#
# Usage:
#   csv2html data.csv                 # writes data.html next to the CSV
#   csv2html data.csv -o report.html
#   csv2html data.csv --open          # write and open in the browser
#   cat data.csv | csv2html - -o report.html
#
#   csv2html data.csv --serve         # serve on 127.0.0.1:8787 and open it
#   csvserve data.csv [port]          # same thing, shorter
#
# In --serve mode the CSV is re-read on every request, so a browser refresh
# (or the page's "auto every 5s" checkbox) shows the current file.
#
# Flags (passed through): -o/--output, -t/--title, -d/--delimiter,
#                         --encoding, --max-rows N, -s/--serve, -p/--port,
#                         --open, --no-open

csv2html() {
  local py="${DEV_ENV_ROOT:-$HOME/Documents/projects/dev-env}/scripts/utils/csv_to_html.py"

  if [[ ! -f "$py" ]]; then
    echo "csv2html: Python script not found at $py" >&2
    return 1
  fi

  if (( $# == 0 )); then
    if [[ ! -t 0 ]]; then
      python3 "$py" -
      return
    fi
    echo "Usage: csv2html <file.csv> [-o out.html] [--open] [--serve]" >&2
    echo "       cat data.csv | csv2html - -o out.html" >&2
    return 1
  fi

  python3 "$py" "$@"
}

# csvserve — serve a CSV over HTTP on localhost (default port 8787)
csvserve() {
  local file="${1:?Usage: csvserve <file.csv> [port]}"
  local port="${2:-8787}"

  csv2html "$file" --serve --port "$port"
}
