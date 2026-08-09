# csv2html — render a CSV as a self-contained interactive HTML report
#
# Usage:
#   csv2html data.csv                 # writes data.html next to the CSV
#   csv2html data.csv -o report.html
#   csv2html data.csv --open          # write and open in the browser
#   cat data.csv | csv2html - -o report.html
#
# Flags (passed through): -o/--output, -t/--title, -d/--delimiter,
#                         --encoding, --max-rows N, --open

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
    echo "Usage: csv2html <file.csv> [-o out.html] [--open]" >&2
    echo "       cat data.csv | csv2html - -o out.html" >&2
    return 1
  fi

  python3 "$py" "$@"
}
