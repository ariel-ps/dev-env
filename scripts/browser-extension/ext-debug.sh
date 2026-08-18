# ext-debug — build/collect/archive tooling for the browser_extension repo's `debug-artifacts`
# branch, which emits diagnostic artifacts about a live browsing session (settings, rule
# decisions, DOM selector matches, network classification) so a bug can be reproduced once and
# handed to an LLM instead of a back-and-forth "run this console snippet" loop.
#
#   ext-debug-run                  # the only command you need day to day:
#                                   # syncs the debug-artifacts branch, npm ci if the lockfile
#                                   # changed, stamps the build marker, runs `make all`, then
#                                   # prints exactly where to Load unpacked
#   ext-debug-collect [name]       # after reproducing: picks the newest exported debug-logs
#                                   # download out of ~/Downloads, files it into archives/<name>/,
#                                   # splits it into bg.log/content.log/main.log/production.log,
#                                   # and zips the folder to archives/<name>.zip
#   ext-debug-context [name]       # turns an archived bundle into one LLM-ready text file,
#                                   # redaction guarantee restated up top, grouped by context
#   ext-debug-archive-list         # list saved archives, newest first, with size
#   ext-debug-archive-rm <name>    # delete one archived bundle
#   goto_ext_debug_data            # cd into $EXT_DEBUG_CACHE (checkout, archives, build log)
#   ext-debug-log                  # tail -f the build/tool log
#   ext-debug-update               # merge current main into debug-artifacts and push (personal
#                                   # branch - never a PR; see the branch's own commit history)
#
#   ext-debug-sync / ext-debug-build   # (rarely needed directly - run does both)
#
# There is nothing to "start" here (unlike ps-agent's mitm-debug) - a browser extension has no
# process, no port, no system-wide proxy. ext-debug-run only builds the branch and tells you
# where to Load unpacked; the diagnostic capture happens inside the browser itself and comes
# out through the extension's own existing "Download Logs" feature (background's `saveLogs`
# message -> content.ts's downloadLogs()), which lands in ~/Downloads as a .txt file -
# ext-debug-collect just picks that up. There's no way for extension code to write to an
# arbitrary path, and this branch doesn't get an exemption from that sandbox.
#
# $EXT_DEBUG_BRANCH (default: debug-artifacts) is meant to be a personal/local-only branch on
# the browser_extension repo, never a PR branch - ext-debug-run always resets to the latest
# commit on it before building, so just push more commits (or run ext-debug-update to merge
# current main into it) to update it.
#
# This build is designed to run ALONGSIDE a real installed copy of the extension on the same
# page: the three page-global markers a real copy and a debug copy would otherwise collide on
# (the MAIN-world init guard, the handshake-token delivery slot, and the RPC port-offer marker)
# are suffixed on this branch so neither copy can short-circuit or steal the other's handshake.
# The actual RPC crypto/validation is untouched - see the branch's own code comments.
#
# Everything ext-debug touches lives under $EXT_DEBUG_CACHE:
#   browser_extension-<branch>/   the synced checkout ext-debug-build runs `make all` in -
#                                  also the "Load unpacked" target for Chrome; its firefox/
#                                  subfolder (built by `make compile`) is the Firefox target
#   ext-debug.log                 build/tool log
#   archives/<name>/               collected bundles (raw log + index)
#   .npm-ci-stamp                 hash of package-lock.json as of the last `npm ci`

# Computes every var this file uses as true globals (plain assignment, no `local`) so they're
# always fresh and available to whichever function calls this first - top-level assignments
# don't survive Claude Code's shell snapshot, only function bodies do (see
# check-snapshot-safety.sh). Every function below that touches any EXT_DEBUG_* / _EXT_DEBUG_*
# var calls this as its first line. Never name a local `path` in zsh - it's tied to $PATH and
# blanks it for the rest of the function's scope; this file uses `entry`/`target` instead.
__ext_debug_paths() {
  # --- user-tunable (env-overridable) ---
  EXT_DEBUG_CACHE="${EXT_DEBUG_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/dev-env-browser-extension}"
  EXT_DEBUG_BRANCH="${EXT_DEBUG_BRANCH:-debug-artifacts}"
  _EXT_DEBUG_REPO="${EXT_DEBUG_REPO:-git@github.com:prompt-security/browser_extension.git}"

  # --- derived paths - all state lives under one cache dir ---
  _EXT_DEBUG_CHECKOUT="$EXT_DEBUG_CACHE/browser_extension-${EXT_DEBUG_BRANCH}"
  _EXT_DEBUG_LOGFILE="$EXT_DEBUG_CACHE/ext-debug.log"
  _EXT_DEBUG_ARCHIVE_DIR="$EXT_DEBUG_CACHE/archives"
  _EXT_DEBUG_NPM_STAMP="$EXT_DEBUG_CACHE/.npm-ci-stamp"
  _EXT_DEBUG_BUILD_MARKER_FILE="$_EXT_DEBUG_CHECKOUT/src/debugBuildInfo.ts"
  _EXT_DEBUG_DOWNLOADS="${EXT_DEBUG_DOWNLOADS:-$HOME/Downloads}"
  # Prefix only, not the full glob pattern: this file is sourced into zsh (see init.zsh), and
  # zsh does NOT glob-expand a pattern stored inside a variable by default (no GLOB_SUBST) -
  # unlike bash, `p='*.txt'; ls $p` silently fails to match anything. Keeping the `*`/`.txt`
  # literal in the call site (glob-chars written directly in the command, only the prefix comes
  # from a variable) avoids the whole issue instead of relying on a zsh-specific option.
  _EXT_DEBUG_DOWNLOAD_PREFIX="prompt_security_extension_debug_logs"
}

ext-debug-sync() {
  __ext_debug_paths
  mkdir -p "$EXT_DEBUG_CACHE"
  if [ -d "$_EXT_DEBUG_CHECKOUT/.git" ]; then
    echo "ext-debug-sync: pulling ${EXT_DEBUG_BRANCH} ..."
    (cd "$_EXT_DEBUG_CHECKOUT" && git fetch origin "$EXT_DEBUG_BRANCH" \
      && git checkout -q "$EXT_DEBUG_BRANCH" && git reset --hard "origin/$EXT_DEBUG_BRANCH")
  else
    echo "ext-debug-sync: cloning ${EXT_DEBUG_BRANCH} ..."
    git clone --branch "$EXT_DEBUG_BRANCH" --single-branch "$_EXT_DEBUG_REPO" "$_EXT_DEBUG_CHECKOUT"
  fi
}

# Rewrites the committed debugBuildInfo.ts default with this checkout's real branch/merge-base/
# build time, so a collected bundle can self-identify which merge-base of main it came from
# (.debug-branch-spec.md #5). Mirrors mitm-debug's __mitm_debug_ensure_config pattern: always
# rewritten, never just-once, so a stale merge-base can't survive a later sync.
__ext_debug_write_build_marker() {
  __ext_debug_paths
  local merge_base built_at
  merge_base="$(cd "$_EXT_DEBUG_CHECKOUT" && git merge-base HEAD "origin/main" 2>/dev/null)" || merge_base="unknown"
  built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$_EXT_DEBUG_BUILD_MARKER_FILE" <<EOF
// Overwritten by ext-debug-build (dev-env). See .debug-branch-spec.md #5.
export const DEBUG_BUILD_MARKER = {
    branch: '${EXT_DEBUG_BRANCH}',
    mergeBase: '${merge_base}',
    builtAt: '${built_at}',
};
EOF
  echo "ext-debug: build marker -> mergeBase=${merge_base} builtAt=${built_at}"
}

ext-debug-build() {
  __ext_debug_paths
  ext-debug-sync || return 1
  mkdir -p "$EXT_DEBUG_CACHE"

  local lockfile="$_EXT_DEBUG_CHECKOUT/package-lock.json" lock_hash=""
  if [ -f "$lockfile" ]; then
    lock_hash="$(shasum -a 256 "$lockfile" | awk '{print $1}')"
  fi
  if [ ! -f "$_EXT_DEBUG_NPM_STAMP" ] || [ "$(cat "$_EXT_DEBUG_NPM_STAMP" 2>/dev/null)" != "$lock_hash" ]; then
    echo "ext-debug-build: lockfile changed (or first build), running npm ci ..."
    if ! (cd "$_EXT_DEBUG_CHECKOUT" && npm ci) >>"$_EXT_DEBUG_LOGFILE" 2>&1; then
      echo "ext-debug-build: npm ci failed - see $_EXT_DEBUG_LOGFILE" >&2
      return 1
    fi
    echo "$lock_hash" > "$_EXT_DEBUG_NPM_STAMP"
  fi

  __ext_debug_write_build_marker

  echo "ext-debug-build: running make all (log -> $_EXT_DEBUG_LOGFILE) ..."
  if ! (cd "$_EXT_DEBUG_CHECKOUT" && make all) >>"$_EXT_DEBUG_LOGFILE" 2>&1; then
    echo "ext-debug-build: make all failed - see $_EXT_DEBUG_LOGFILE" >&2
    return 1
  fi
  echo "ext-debug-build: done"
  echo "  Chrome (unpacked)  -> $_EXT_DEBUG_CHECKOUT"
  echo "  Firefox (unpacked) -> $_EXT_DEBUG_CHECKOUT/firefox"
}

ext-debug-run() {
  __ext_debug_paths
  ext-debug-build || return 1
  echo ""
  echo "Load unpacked (alongside your real installed copy is fine - see the branch's page-global"
  echo "marker suffixing, ext-debug.sh header):"
  echo "  Chrome:  chrome://extensions -> Developer mode -> Load unpacked -> $_EXT_DEBUG_CHECKOUT"
  echo "  Firefox: about:debugging#/runtime/this-firefox -> Load Temporary Add-on ->"
  echo "           $_EXT_DEBUG_CHECKOUT/firefox/manifest.json"
  echo "Reproduce the bug, then: ext-debug-collect <name>"
}

ext-debug-log() {
  __ext_debug_paths
  if [ ! -f "$_EXT_DEBUG_LOGFILE" ]; then
    echo "ext-debug-log: no log yet at $_EXT_DEBUG_LOGFILE - has ext-debug-build been run?" >&2
    return 1
  fi
  tail -f "$_EXT_DEBUG_LOGFILE"
}

goto_ext_debug_data() {
  __ext_debug_paths
  _goto_project "$EXT_DEBUG_CACHE"
}

# Picks the newest debug-logs export out of ~/Downloads (Chrome/Firefox suffix repeat downloads
# as "... (1).txt" etc - newest mtime wins regardless of the suffix) and files it into
# archives/<name>/ alongside a generated index (.debug-branch-spec.md #6.4): counts per
# [DBG:bg]/[DBG:content]/[DBG:main] tag, provider domains mentioned, session time window, and
# an explicit "what's empty" section so a silent gap doesn't read as full coverage.
ext-debug-collect() {
  __ext_debug_paths
  local name="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
  local dest="$_EXT_DEBUG_ARCHIVE_DIR/$name"
  if [ -e "$dest" ]; then
    echo "ext-debug-collect: $dest already exists - pick another name" >&2
    return 1
  fi

  local newest
  newest="$(ls -t "$_EXT_DEBUG_DOWNLOADS"/${_EXT_DEBUG_DOWNLOAD_PREFIX}*.txt 2>/dev/null | head -1)"
  if [ -z "$newest" ]; then
    echo "ext-debug-collect: no '${_EXT_DEBUG_DOWNLOAD_PREFIX}*.txt' found in $_EXT_DEBUG_DOWNLOADS" >&2
    echo "  In the extension popup, use Download Logs after reproducing the bug." >&2
    return 1
  fi

  mkdir -p "$dest"
  mv "$newest" "$dest/debug_logs.txt"

  # Per-context split files, alongside (not instead of) the full chronological log - splitting
  # loses cross-context correlation by proximity, so debug_logs.txt stays the source of truth
  # for ext-debug-context; these are for skimming/sharing one context at a time.
  grep '\[DBG:bg\]' "$dest/debug_logs.txt" > "$dest/bg.log"
  grep '\[DBG:content\]' "$dest/debug_logs.txt" > "$dest/content.log"
  grep '\[DBG:main\]' "$dest/debug_logs.txt" > "$dest/main.log"
  grep -v '\[DBG:bg\]\|\[DBG:content\]\|\[DBG:main\]' "$dest/debug_logs.txt" > "$dest/production.log"

  local total bg content main other first_ts last_ts domains
  total="$(wc -l < "$dest/debug_logs.txt" | tr -d ' ')"
  bg="$(wc -l < "$dest/bg.log" | tr -d ' ')"
  content="$(wc -l < "$dest/content.log" | tr -d ' ')"
  main="$(wc -l < "$dest/main.log" | tr -d ' ')"
  other="$(wc -l < "$dest/production.log" | tr -d ' ')"
  # Real lines look like "8/18/2026, 7:24:01 PM GMT+03:00 - script  [INFO] ..." (a
  # toLocaleString-shaped timestamp, not ISO8601) - split on " - " (timestamp/context
  # separator) rather than assuming a specific date format, which silently matched just the
  # leading digit before the first "/" and printed "Session window: 8 -> 8" in a real test run.
  first_ts="$(head -1 "$dest/debug_logs.txt" | awk -F' - ' '{print $1}')"
  last_ts="$(tail -1 "$dest/debug_logs.txt" | awk -F' - ' '{print $1}')"
  first_ts="${first_ts:-unknown}"
  last_ts="${last_ts:-unknown}"
  domains="$(grep -oE '(chatgpt\.com|claude\.ai|gemini\.google\.com|www\.perplexity\.ai|copilot\.microsoft\.com|www\.copilot\.com)' "$dest/debug_logs.txt" | sort -u | tr '\n' ',' | sed 's/,$//')"

  cat > "$dest/index.md" <<EOF
# ext-debug bundle: $name

**To the LLM reading this**: this bundle is a diagnostic capture from the \`debug-artifacts\`
branch of \`prompt-security/browser_extension\` - a personal, never-merged build whose only
purpose is giving you enough ground truth to diagnose a reported bug in one shot, without asking
the user to run console snippets. \`debug_logs.txt\` is the source of truth: one continuous,
chronologically ordered log from a single browsing session, interleaving three execution
contexts - correlate across them using shared \`flowTraceId\`/\`conversationId\` values, not just
proximity (splitting by context, as the four files below do, loses that cross-context ordering).
- \`bg.log\` (\`[DBG:bg]\`) - the extension's background/service worker (settings, rule/domain-
  action decisions, backend calls, SW lifecycle)
- \`content.log\` (\`[DBG:content]\`) - the content script, isolated world (DOM selector matches,
  state-signature block/allow decisions, RPC handshake state, modals shown)
- \`main.log\` (\`[DBG:main]\`) - the injected script, MAIN world (page event firehose, fetch/XHR/
  WS classification, account/config endpoint bodies)
- \`production.log\` - lines with **no** \`[DBG:*]\` tag: the extension's normal, real production
  logging (actual rule evaluations, block/allow events, backend calls) - not synthetic, not debug-only.
Use the split files to skim one context in isolation or attach just one to a narrow question;
use \`debug_logs.txt\` (or \`ext-debug-context\`'s output) when order/correlation matters.

Redaction guarantee: every \`[DBG:*]\` line went through the extension's shared redaction helper
(\`src/utils/debugRedact.ts\`) before logging - no prompt content, cookie values, tokens, or
keystrokes. Verify with: \`grep -i "authorization\|password\|<a real prompt string you typed>" debug_logs.txt\` (expect zero hits) before this bundle leaves your machine.

- Session window: $first_ts -> $last_ts
- Provider domains seen: ${domains:-none}
- Total lines: $total
- [DBG:bg] (background/service worker): $bg
- [DBG:content] (content script, isolated world): $content
- [DBG:main] (injected script, MAIN world): $main
- other (non-debug extension logs, e.g. real block/allow decisions): $other

## What's NOT captured
- Anything this branch doesn't instrument yet (e.g. providers added to the codebase after this
  bundle's merge-base - see debug_logs.txt's own [DBG:bg] service-worker-wake line for the
  mergeBase this build was cut from).
- 0 counts above for a category mean that context produced no debug lines this session, not
  that it was skipped - check whether that context ran at all (e.g. did the page ever reach the
  provider's composer) before concluding it's a gap in the branch.
EOF

  echo "ext-debug-collect: saved -> $dest"
  du -sh "$dest" 2>/dev/null

  # Zip alongside the folder (not instead of it) - the folder stays the working copy
  # ext-debug-context reads from; the zip is just the one-file artifact to attach to a ticket
  # or paste into a chat upload.
  if command -v zip >/dev/null 2>&1; then
    (cd "$_EXT_DEBUG_ARCHIVE_DIR" && zip -rq "$name.zip" "$name")
    echo "ext-debug-collect: zipped -> $_EXT_DEBUG_ARCHIVE_DIR/$name.zip"
  else
    echo "ext-debug-collect: 'zip' not found on PATH, skipping the .zip (folder is still at $dest)" >&2
  fi
}

# Concatenates an archived bundle into one LLM-ready file: index first, then the raw log
# (already chronological and tagged per-context) - the "payoff command" per
# .debug-branch-spec.md #7. Kept as plain concatenation rather than re-grouping by context:
# interleaved chronological order is what lets an LLM correlate a background rule decision with
# the content-script selector check and the MAIN-world fetch that happened around the same time.
ext-debug-context() {
  __ext_debug_paths
  local name="$1"
  if [ -z "$name" ]; then
    echo "ext-debug-context: usage: ext-debug-context <name> (see ext-debug-archive-list)" >&2
    return 1
  fi
  local target="$_EXT_DEBUG_ARCHIVE_DIR/$name"
  if [ ! -d "$target" ]; then
    echo "ext-debug-context: no archive named '$name' in $_EXT_DEBUG_ARCHIVE_DIR" >&2
    return 1
  fi
  cat "$target/index.md"
  echo ""
  echo "---"
  echo ""
  echo '```'
  cat "$target/debug_logs.txt"
  echo '```'
}

ext-debug-archive-list() {
  __ext_debug_paths
  local dir="$_EXT_DEBUG_ARCHIVE_DIR"
  if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "ext-debug-archive-list: no archives yet in $dir" >&2
    return 0
  fi
  local entry name mtime size
  for entry in $(ls -1t "$dir"); do
    entry="$dir/$entry"
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    mtime="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$entry")"
    size="$(du -sh "$entry" 2>/dev/null | cut -f1)"
    printf "%-10s  %s  %s\n" "$size" "$mtime" "$name"
  done
}

ext-debug-archive-rm() {
  __ext_debug_paths
  local name="$1"
  if [ -z "$name" ]; then
    echo "ext-debug-archive-rm: usage: ext-debug-archive-rm <name>" >&2
    return 1
  fi
  local target="$_EXT_DEBUG_ARCHIVE_DIR/$name"
  if [ ! -d "$target" ]; then
    echo "ext-debug-archive-rm: no archive named '$name' in $_EXT_DEBUG_ARCHIVE_DIR" >&2
    return 1
  fi
  rm -rf "$target"
  rm -f "$_EXT_DEBUG_ARCHIVE_DIR/$name.zip"
  echo "ext-debug-archive-rm: removed $target"
}

# Periodic refresh: merge (not rebase - this is a long-lived published branch; rebasing would
# force --force-push and break every existing checkout, including this one's
# `git reset --hard origin/$EXT_DEBUG_BRANCH` in ext-debug-sync) current main into
# debug-artifacts and push. .debug-branch-spec.md #5.
ext-debug-update() {
  __ext_debug_paths
  ext-debug-sync || return 1
  (cd "$_EXT_DEBUG_CHECKOUT" \
    && git fetch origin main \
    && git merge origin/main -m "Merge main into ${EXT_DEBUG_BRANCH}" \
    && git push origin "$EXT_DEBUG_BRANCH")
}
