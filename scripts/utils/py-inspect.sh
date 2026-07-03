# py-inspect — run PyCharm static analysis on a Python project (headless)
#
# Usage:
#   py-inspect <project-dir>
#   py-inspect <project-dir> <output-dir>
#
# Output XML files land in <output-dir> (default: /tmp/py-inspect-results).
# Requires PyCharm at /Applications/PyCharm.app.

py-inspect() {
  local inspect_sh="/Applications/PyCharm.app/Contents/bin/inspect.sh"
  local project_dir="${1:?Usage: py-inspect <project-dir> [output-dir]}"
  local output_dir="${2:-/tmp/py-inspect-results}"

  if [[ ! -x "$inspect_sh" ]]; then
    echo "py-inspect: PyCharm inspect.sh not found at $inspect_sh" >&2
    return 1
  fi

  if [[ ! -d "$project_dir" ]]; then
    echo "py-inspect: project dir not found: $project_dir" >&2
    return 1
  fi

  project_dir="$(cd "$project_dir" && pwd)"
  mkdir -p "$output_dir"

  echo "py-inspect: scanning $project_dir → $output_dir"
  "$inspect_sh" "$project_dir" "$project_dir" "$output_dir" -format xml

  local count
  count=$(find "$output_dir" -name "*.xml" | wc -l | tr -d ' ')
  echo "py-inspect: done — $count result file(s) in $output_dir"
}
