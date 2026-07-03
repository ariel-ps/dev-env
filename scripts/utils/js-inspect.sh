# js-inspect — run WebStorm static analysis on a JS/TS project (headless)
#
# Usage:
#   js-inspect <project-dir>
#   js-inspect <project-dir> <output-dir>
#
# Output XML files land in <output-dir> (default: /tmp/js-inspect-results).
# Requires WebStorm at /Applications/WebStorm.app.

js-inspect() {
  local inspect_sh="/Applications/WebStorm.app/Contents/bin/inspect.sh"
  local project_dir="${1:?Usage: js-inspect <project-dir> [output-dir]}"
  local output_dir="${2:-/tmp/js-inspect-results}"

  if [[ ! -x "$inspect_sh" ]]; then
    echo "js-inspect: WebStorm inspect.sh not found at $inspect_sh" >&2
    return 1
  fi

  if [[ ! -d "$project_dir" ]]; then
    echo "js-inspect: project dir not found: $project_dir" >&2
    return 1
  fi

  project_dir="$(cd "$project_dir" && pwd)"
  mkdir -p "$output_dir"

  echo "js-inspect: scanning $project_dir → $output_dir"
  "$inspect_sh" "$project_dir" "$project_dir" "$output_dir" -format xml

  local count
  count=$(find "$output_dir" -name "*.xml" | wc -l | tr -d ' ')
  echo "js-inspect: done — $count result file(s) in $output_dir"
}
