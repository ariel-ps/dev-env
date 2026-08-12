# ps-agent test-build automation.
#
# Wraps: waiting for CI build completion (gh run), downloading build
# artifacts + computing their sha256, re-signing the unsigned pkg for local
# install trust (Mac Guard requires a J7M9U73T5B-signed writer), generating
# the exact registry SQL from the real computed hashes, and checking/pushing
# the S3 test path.
#
# Everything except `s3-push` is read-only/non-mutating. `s3-push` is the one
# subcommand that writes to shared state (s3://ps-downloads/test/) — it
# defaults to --dryrun and only actually uploads with an explicit --yes.
#
# Still deliberately NOT wrapped: the release-registry DB write, the
# feature-flag git push, `kubectl set env`, and the VM install — those stay
# fully manual. See MAC-AGENT-TEST-BUILD.md.
#
# Usage:
#   pa-test-build check-versions <v1> <v2>
#   pa-test-build wait <branch> [interval_s=30] [timeout_min=25]
#   pa-test-build fetch <run_id> <outdir>
#   pa-test-build resign <dir>
#   pa-test-build sql <v1> <v2> <dir1> <dir2>
#   pa-test-build s3-check <v1> [v2] [bucket=ps-downloads]
#   pa-test-build s3-push <dir> <version> [--yes] [--force] [--bucket=name]

__pa_test_build_semver_valid() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# true if $1 >= $2 (both bare X.Y.Z semver)
__pa_test_build_semver_ge() {
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# true if $1 > $2
__pa_test_build_semver_gt() {
  [[ "$1" == "$2" ]] && return 1
  __pa_test_build_semver_ge "$1" "$2"
}

__pa_test_build_find_pkg() {
  local dir="$1" pattern="$2"
  # -type f matters: gh run download unpacks each artifact into a directory named
  # after it, so the tree holds a prompt-agent-installer-*.pkg directory with the
  # real pkg inside. Without it find returns the directory and shasum/codesign
  # silently produce nothing.
  find "$dir" -type f -iname "$pattern" 2>/dev/null | head -1
}

pa-test-build() {
  emulate -L zsh
  setopt bareglobqual nullglob
  local cmd="${1:-}"; shift 2>/dev/null

  case "$cmd" in

    check-versions)
      local v1="$1" v2="$2"
      if [[ -z "$v1" || -z "$v2" ]]; then
        echo "usage: pa-test-build check-versions <v1> <v2>" >&2; return 1
      fi
      __pa_test_build_semver_valid "$v1" || { echo "pa-test-build: '$v1' is not X.Y.Z" >&2; return 1; }
      __pa_test_build_semver_valid "$v2" || { echo "pa-test-build: '$v2' is not X.Y.Z" >&2; return 1; }
      __pa_test_build_semver_gt "$v2" "$v1" \
        || { echo "pa-test-build: v2 ($v2) must be higher than v1 ($v1)" >&2; return 1; }
      __pa_test_build_semver_ge "$v1" "4.2.6" \
        || { echo "pa-test-build: v1 ($v1) must be >= 4.2.6" >&2; return 1; }
      __pa_test_build_semver_ge "$v2" "4.2.6" \
        || { echo "pa-test-build: v2 ($v2) must be >= 4.2.6" >&2; return 1; }

      command -v gh >/dev/null 2>&1 || { echo "pa-test-build: gh not found" >&2; return 1; }
      local releases
      releases=$(gh release list -R prompt-security/ps-agent --json tagName --jq '.[].tagName' 2>/dev/null)
      if [[ -z "$releases" ]]; then
        releases=$(gh release list -R prompt-security/ps-agent 2>/dev/null | awk -F'\t' '{print $3}')
      fi
      local tag v
      for v in "$v1" "$v2"; do
        for tag in ${(f)releases}; do
          [[ "${tag#v}" == "$v" ]] \
            && { echo "pa-test-build: $v matches a real release ($tag) — pick a different test version" >&2; return 1; }
        done
      done
      echo "pa-test-build: check-versions ok — $v1 < $v2, both >= 4.2.6, neither is a real release"
      ;;

    wait)
      local branch="$1" interval="${2:-30}" timeout_min="${3:-25}"
      [[ -n "$branch" ]] || { echo "usage: pa-test-build wait <branch> [interval_s] [timeout_min]" >&2; return 1; }
      command -v gh >/dev/null 2>&1 || { echo "pa-test-build: gh not found" >&2; return 1; }
      local deadline=$(( $(date +%s) + timeout_min * 60 ))
      local line run_id status conclusion rest
      while true; do
        line=$(gh run list --branch "$branch" -R prompt-security/ps-agent --limit 1 \
                 --json databaseId,status,conclusion \
                 --jq '.[0] | "\(.databaseId)\t\(.status)\t\(.conclusion)"' 2>/dev/null)
        if [[ -z "$line" ]]; then
          echo "pa-test-build wait: no runs found yet for branch '$branch'" >&2
        else
          run_id="${line%%$'\t'*}"; rest="${line#*$'\t'}"
          status="${rest%%$'\t'*}"; conclusion="${rest#*$'\t'}"
          echo "pa-test-build wait: run $run_id status=$status conclusion=$conclusion"
          if [[ "$status" == "completed" ]]; then
            if [[ "$conclusion" == "success" ]]; then
              print -r -- "$run_id"
              return 0
            fi
            echo "pa-test-build wait: run $run_id finished with conclusion=$conclusion, not success" >&2
            return 1
          fi
        fi
        if (( $(date +%s) >= deadline )); then
          echo "pa-test-build wait: timed out after ${timeout_min}m waiting on branch '$branch'" >&2
          return 1
        fi
        sleep "$interval"
      done
      ;;

    fetch)
      local run_id="$1" outdir="$2"
      if [[ -z "$run_id" || -z "$outdir" ]]; then
        echo "usage: pa-test-build fetch <run_id> <outdir>" >&2; return 1
      fi
      mkdir -p "$outdir" || return 1
      gh run download "$run_id" -R prompt-security/ps-agent \
        -n prompt-agent-installer-apple-silicon.pkg \
        -n prompt-agent-installer-apple-intel.pkg \
        -D "$outdir" || return 1

      local silicon intel sha_silicon sha_intel
      silicon="$(__pa_test_build_find_pkg "$outdir" '*apple-silicon*.pkg')"
      intel="$(__pa_test_build_find_pkg "$outdir" '*apple-intel*.pkg')"
      [[ -n "$silicon" ]] || { echo "pa-test-build fetch: silicon pkg not found under $outdir" >&2; return 1; }
      [[ -n "$intel"   ]] || { echo "pa-test-build fetch: intel pkg not found under $outdir" >&2; return 1; }
      sha_silicon=$(shasum -a 256 "$silicon" | awk '{print $1}')
      sha_intel=$(shasum -a 256 "$intel" | awk '{print $1}')

      {
        printf 'PA_TEST_BUILD_SILICON_PKG=%q\n' "$silicon"
        printf 'PA_TEST_BUILD_INTEL_PKG=%q\n'   "$intel"
        printf 'PA_TEST_BUILD_SILICON_SHA=%q\n' "$sha_silicon"
        printf 'PA_TEST_BUILD_INTEL_SHA=%q\n'   "$sha_intel"
      } > "$outdir/hashes.env"

      echo "pa-test-build fetch: silicon $silicon"
      echo "  sha256 $sha_silicon"
      echo "pa-test-build fetch: intel   $intel"
      echo "  sha256 $sha_intel"
      echo "pa-test-build fetch: wrote $outdir/hashes.env"
      ;;

    resign)
      local dir="$1"
      [[ -n "$dir" ]] || { echo "usage: pa-test-build resign <dir>" >&2; return 1; }
      command -v resign-agent-pkg.sh >/dev/null 2>&1 \
        || { echo "pa-test-build resign: resign-agent-pkg.sh not on PATH — source scripts/ps-agent/pa-api.sh first" >&2; return 1; }
      local pkg rc=0
      for pkg in "$dir"/**/*apple-silicon*.pkg(N) "$dir"/**/*apple-intel*.pkg(N); do
        [[ "$pkg" == *-resigned.pkg ]] && continue
        echo "pa-test-build resign: $pkg"
        resign-agent-pkg.sh "$pkg" || rc=1
      done
      return $rc
      ;;

    s3-check)
      local v1="$1" v2="$2" bucket="${3:-ps-downloads}"
      [[ -n "$v1" ]] || { echo "usage: pa-test-build s3-check <v1> [v2] [bucket=ps-downloads]" >&2; return 1; }
      command -v aws >/dev/null 2>&1 || { echo "pa-test-build: aws not found" >&2; return 1; }
      local existing
      existing=$(aws s3 ls "s3://$bucket/test/" 2>&1) \
        || { echo "pa-test-build s3-check: failed to list s3://$bucket/test/ — $existing" >&2; return 1; }
      local rc=0 v
      for v in "$v1" "$v2"; do
        [[ -z "$v" ]] && continue
        if print -r -- "$existing" | grep -qF "PRE ${v}/"; then
          echo "pa-test-build s3-check: '$v' already exists under s3://$bucket/test/ — pushing will overwrite it" >&2
          rc=1
        fi
      done
      (( rc == 0 )) && echo "pa-test-build s3-check: $v1${v2:+ / $v2} clear — no existing test/<version>/ prefix"
      return $rc
      ;;

    s3-push)
      local dir="$1" version="$2" bucket="ps-downloads" yes=0 force=0
      shift 2 2>/dev/null
      local arg
      for arg in "$@"; do
        case "$arg" in
          --yes) yes=1 ;;
          --force) force=1 ;;
          --bucket=*) bucket="${arg#--bucket=}" ;;
        esac
      done
      if [[ -z "$dir" || -z "$version" ]]; then
        echo "usage: pa-test-build s3-push <dir> <version> [--yes] [--force] [--bucket=name]" >&2
        return 1
      fi
      command -v aws >/dev/null 2>&1 || { echo "pa-test-build: aws not found" >&2; return 1; }

      if (( ! force )); then
        pa-test-build s3-check "$version" "" "$bucket" \
          || { echo "pa-test-build s3-push: refusing — pass --force to overwrite anyway" >&2; return 1; }
      fi

      local silicon intel
      silicon="$(find "$dir" -type f -iname '*apple-silicon*.pkg' ! -iname '*-resigned.pkg' 2>/dev/null | head -1)"
      intel="$(find "$dir" -type f -iname '*apple-intel*.pkg' ! -iname '*-resigned.pkg' 2>/dev/null | head -1)"
      [[ -n "$silicon" ]] || { echo "pa-test-build s3-push: silicon pkg not found under $dir" >&2; return 1; }
      [[ -n "$intel"   ]] || { echo "pa-test-build s3-push: intel pkg not found under $dir" >&2; return 1; }

      local -a dryrun=(--dryrun)
      if (( yes )); then
        dryrun=()
      else
        echo "pa-test-build s3-push: DRY RUN — pass --yes to actually upload"
      fi

      aws s3 cp "${dryrun[@]}" "$silicon" "s3://$bucket/test/$version/macos/prompt_agent_installer.pkg" || return 1
      aws s3 cp "${dryrun[@]}" "$intel"   "s3://$bucket/test/$version/macos_intel/prompt_agent_installer.pkg" || return 1
      ;;

    sql)
      local v1="$1" v2="$2" dir1="$3" dir2="$4"
      if [[ -z "$v1" || -z "$v2" || -z "$dir1" || -z "$dir2" ]]; then
        echo "usage: pa-test-build sql <v1> <v2> <dir1> <dir2>" >&2; return 1
      fi
      [[ -f "$dir1/hashes.env" ]] || { echo "pa-test-build sql: missing $dir1/hashes.env — run 'pa-test-build fetch' first" >&2; return 1; }
      [[ -f "$dir2/hashes.env" ]] || { echo "pa-test-build sql: missing $dir2/hashes.env — run 'pa-test-build fetch' first" >&2; return 1; }
      local PA_TEST_BUILD_SILICON_SHA PA_TEST_BUILD_INTEL_SHA
      local sha1_silicon sha1_intel sha2_silicon sha2_intel
      source "$dir1/hashes.env"; sha1_silicon="$PA_TEST_BUILD_SILICON_SHA"; sha1_intel="$PA_TEST_BUILD_INTEL_SHA"
      source "$dir2/hashes.env"; sha2_silicon="$PA_TEST_BUILD_SILICON_SHA"; sha2_intel="$PA_TEST_BUILD_INTEL_SHA"

      cat <<SQL
INSERT INTO agent_release_registry (id, version, os, arch, "artifactUrl", sha256, visibility, "publishedAt") VALUES
(gen_random_uuid(),'$v1','darwin','arm64', 'https://downloads.prompt.security/test/$v1/macos/prompt_agent_installer.pkg',       '$sha1_silicon','public', now()),
(gen_random_uuid(),'$v1','darwin','x86_64','https://downloads.prompt.security/test/$v1/macos_intel/prompt_agent_installer.pkg', '$sha1_intel',  'public', now()),
(gen_random_uuid(),'$v2','darwin','arm64', 'https://downloads.prompt.security/test/$v2/macos/prompt_agent_installer.pkg',       '$sha2_silicon','public', now()),
(gen_random_uuid(),'$v2','darwin','x86_64','https://downloads.prompt.security/test/$v2/macos_intel/prompt_agent_installer.pkg', '$sha2_intel',  'public', now())
ON CONFLICT (version, os, arch) DO UPDATE SET "artifactUrl"=EXCLUDED."artifactUrl", sha256=EXCLUDED.sha256, "publishedAt"=EXCLUDED."publishedAt";
SQL
      ;;

    ""|-h|--help|help)
      cat <<'EOF'
pa-test-build — safe, non-mutating helpers for mac agent test builds

  check-versions <v1> <v2>        v2>v1, both >=4.2.6, neither a real release
  wait <branch> [interval_s] [timeout_min]
                                   poll CI until the run on <branch> completes,
                                   prints run id on success (exit 0), else exit 1
  fetch <run_id> <outdir>          gh run download both mac pkgs + compute/save sha256
  resign <dir>                    re-sign every unsigned pkg under <dir> (needs
                                   pa-api.sh sourced first, puts resign-agent-pkg.sh on PATH)
  sql <v1> <v2> <dir1> <dir2>      print the registry INSERT with real hashes filled in
  s3-check <v1> [v2] [bucket]      warn if version(s) already exist under s3://<bucket>/test/
  s3-push <dir> <version> [--yes] [--force] [--bucket=name]
                                   upload dir's pkgs to s3://<bucket>/test/<version>/ —
                                   dry-run unless --yes; refuses on collision unless --force

s3-push is the only subcommand that writes to shared state. Registry DB write,
feature-flag git push, kubectl set env, and the VM install stay fully manual,
see MAC-AGENT-TEST-BUILD.md.
EOF
      ;;

    *)
      echo "pa-test-build: unknown subcommand '$cmd' (try 'pa-test-build help')" >&2
      return 1
      ;;
  esac
}

__pa_test_build_complete() { compadd check-versions wait fetch resign sql s3-check s3-push help }
compdef __pa_test_build_complete pa-test-build
