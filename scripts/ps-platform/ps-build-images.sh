# ps-build-images — dispatch the ps-platform "Build and Push Docker Image
# (monorepo)" workflow for a branch, watch it, then print the GHCR image
# names it pushed.
#
# The workflow is workflow_dispatch-only. It builds the nx-affected
# microservices (everything except ps-platform itself) and pushes each to:
#     ghcr.io/ps-prod/<service>:<branch>
#     ghcr.io/ps-customers/<service>:<branch>     (mirror)
# where <branch> is the branch name with every non-[alnum_] character
# replaced by '-' (matching the workflow's own sanitizer).
#
# Usage:
#   ps-build-images [options]
#
# Options:
#   -b, --branch BRANCH   Branch to build (default: current git branch)
#   -n, --no-watch        Dispatch the workflow and return without watching
#       --images-only     Do not dispatch; just print the images from the
#                         latest image-build run of the branch
#       --repo REPO       GitHub repo (default: $PS_PLATFORM_REPO or
#                         prompt-security/ps-platform)
#   -h, --help            Show help
#
# Requires: gh (authenticated), git.
ps-build-images() {
  local repo="${PS_PLATFORM_REPO:-prompt-security/ps-platform}"
  local workflow="${PS_PLATFORM_IMAGE_WORKFLOW:-build-push-docker-image-ps-platform.yml}"
  local branch="" watch=1 images_only=0 services=""

  _psbi_usage() {
    cat <<'EOF'
ps-build-images — build & push ps-platform branch images via GitHub Actions,
then print the GHCR image names.

Usage:
  ps-build-images [options]

Options:
  -b, --branch BRANCH   Branch to build (default: current git branch)
  -n, --no-watch        Dispatch the workflow and return without watching
      --images-only     Do not dispatch; just print images from the latest
                        image-build run of the branch
      --repo REPO       GitHub repo (default: $PS_PLATFORM_REPO or
                        prompt-security/ps-platform)
  -h, --help            Show this help

Examples:
  ps-build-images                          # current branch: dispatch, watch, list
  ps-build-images --branch my-feature
  ps-build-images -b my-feature --no-watch
  ps-build-images --images-only            # just print images of the latest run
EOF
  }

  _psbi_need() {
    command -v gh >/dev/null 2>&1 || { echo "[ps-build-images] gh CLI not found on PATH" >&2; return 1; }
    gh auth status --hostname github.com >/dev/null 2>&1 || { echo "[ps-build-images] gh not authenticated — run 'gh auth login'" >&2; return 1; }
  }
  # Mirror the workflow's sanitize_docker_tag(): non-[alnum_] -> '-'.
  _psbi_tag() { printf '%s' "$1" | sed 's/[^[:alnum:]_]/-/g'; }
  _psbi_curbranch() { git rev-parse --abbrev-ref HEAD 2>/dev/null; }

  # Services built by a run = matrix values of its build-and-push jobs.
  _psbi_services() {
    gh run view "$1" --repo "$repo" --json jobs --jq '.jobs[].name' 2>/dev/null \
      | grep -oE 'build-and-push \([a-z0-9_-]+\)' \
      | sed -E 's/.*\(([a-z0-9_-]+)\).*/\1/' \
      | sort -u
  }

  _psbi_print_images() {
    local run_id="$1" branch="$2" tag svc services
    tag="$(_psbi_tag "$branch")"
    services="$(_psbi_services "$run_id")"
    if [ -z "$services" ]; then
      echo "[ps-build-images] no built services found for run $run_id (nothing affected, or run not finished)" >&2
      return 1
    fi
    echo "Images pushed (tag: $tag):"
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      echo "  ghcr.io/ps-prod/$svc:$tag"
      echo "  ghcr.io/ps-customers/$svc:$tag"
    done <<< "$services"
  }

  # --- parse options (GNU-style: --flag, --flag value, --flag=value) ---
  while [ $# -gt 0 ]; do
    case "$1" in
      -b|--branch)
        [ -n "$2" ] || { echo "[ps-build-images] missing value for $1" >&2; return 2; }
        branch="$2"; shift 2 ;;
      --branch=*)   branch="${1#*=}"; shift ;;
      -s|--service|--services)
        [ -n "$2" ] || { echo "[ps-build-images] missing value for $1" >&2; return 2; }
        services="$2"; shift 2 ;;
      --service=*|--services=*) services="${1#*=}"; shift ;;
      --repo)
        [ -n "$2" ] || { echo "[ps-build-images] missing value for $1" >&2; return 2; }
        repo="$2"; shift 2 ;;
      --repo=*)     repo="${1#*=}"; shift ;;
      -n|--no-watch) watch=0; shift ;;
      --images-only) images_only=1; shift ;;
      -h|--help)    _psbi_usage; return 0 ;;
      --)           shift; break ;;
      -*)           echo "[ps-build-images] unknown option: $1" >&2; _psbi_usage >&2; return 2 ;;
      *)            echo "[ps-build-images] unexpected argument: $1 (did you mean --branch $1 ?)" >&2; return 2 ;;
    esac
  done

  _psbi_need || return 1
  [ -n "$branch" ] || branch="$(_psbi_curbranch)"
  [ -n "$branch" ] || { echo "[ps-build-images] no --branch given and not in a git repo" >&2; return 2; }

  # --images-only: no dispatch, report the latest finished run.
  if [ "$images_only" -eq 1 ]; then
    local run_id
    run_id="$(gh run list --repo "$repo" --workflow "$workflow" --branch "$branch" \
              --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
    [ -n "$run_id" ] || { echo "[ps-build-images] no image-build run found for branch '$branch'" >&2; return 1; }
    _psbi_print_images "$run_id" "$branch"
    return $?
  fi

  echo "[ps-build-images] dispatching $workflow on $repo @ $branch ..."
  gh workflow run "$workflow" --repo "$repo" --ref "$branch" -f build_image=true -f services="$services" || return 1

  # Dispatch is async; poll briefly for the run we just created.
  local run_id="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    run_id="$(gh run list --repo "$repo" --workflow "$workflow" --branch "$branch" \
              --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
    [ -n "$run_id" ] && break
    sleep 2
  done
  [ -n "$run_id" ] || { echo "[ps-build-images] dispatched, but could not locate the run — try: gh run list --repo $repo --workflow $workflow" >&2; return 1; }

  echo "[ps-build-images] run: https://github.com/$repo/actions/runs/$run_id"
  if [ "$watch" -eq 0 ]; then
    echo "[ps-build-images] dispatched (not watching). When it finishes: ps-build-images --images-only --branch $branch"
    return 0
  fi

  gh run watch "$run_id" --repo "$repo" --exit-status
  local rc=$?
  echo
  _psbi_print_images "$run_id" "$branch"
  [ $rc -eq 0 ] || echo "[ps-build-images] note: run did not finish successfully (exit $rc) — image list may be incomplete" >&2
  return $rc
}

# zsh completion for the flags
if command -v compdef >/dev/null 2>&1; then
  _ps_build_images() {
    _arguments \
      '(-b --branch)'{-b,--branch}'[branch to build (default: current git branch)]:branch:' \
      '(-n --no-watch)'{-n,--no-watch}'[dispatch only, do not watch]' \
      '--images-only[do not dispatch; print images of the latest run]' \
      '--repo[GitHub repo]:repo:' \
      '(-h --help)'{-h,--help}'[show help]'
  }
  compdef _ps_build_images ps-build-images
fi
