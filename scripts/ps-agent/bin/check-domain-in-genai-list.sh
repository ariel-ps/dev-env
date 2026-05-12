#!/usr/bin/env bash
#
# ─────────────────────────────────────────────────────────────────────────
#  check-domain-in-genai-list.sh
#
#  Verify whether a domain is registered in the Prompt Security backend's
#  GenAI domain list. The browser extension only protects domains whose
#  SHA-1 hash appears in either:
#
#    • the global GenAI list  (genAiApps.globalDomainHashes)
#    • this tenant's custom list  (customGenAiAppsDomainHashes)
#
#  If neither list contains the domain's hash, the extension correctly
#  classifies it as a non-GenAI site and never attempts to show a popup,
#  block page, or inspection warning. That is by design — not a bug.
#
#  This script reproduces, from the command line, exactly what the
#  extension does in src/background/siteManagement/siteActions.ts
#  (function getDomainInfoV2). It serves as proof that a given domain is
#  or is not in the backend's GenAI catalogue.
#
#  ── Usage ────────────────────────────────────────────────────────────
#
#     export PROMPT_API_DOMAIN="staging-eu.prompt.security"
#     export PROMPT_API_KEY="<your APP-ID>"
#
#     ./check-domain-in-genai-list.sh stepfun.ai
#     ./check-domain-in-genai-list.sh stepfun.ai chat.openai.com claude.ai
#
#  Exit code is 0 when every domain checked is in some GenAI list,
#  1 when at least one domain is missing.
#
#  ── Optional environment variables ─────────────────────────────────
#     EXT_VERSION   default 7.1.6   — extension version reported to backend
#     USER_UUID     default zeros   — any UUID; read-only calls don't care
#     CONFIG_FILE   default tmp     — where to cache the downloaded config
#     FORCE         default 0       — set to 1 to refetch even if cached
# ─────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ─── colors ──────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
    C_RESET=$'\033[0m'
else
    C_BOLD=''; C_DIM=''; C_GREEN=''; C_RED=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi

say()        { printf '%s\n' "$*"; }
header()     { printf '\n%s━━━ %s ━━━%s\n' "$C_BOLD" "$1" "$C_RESET"; }
ok()         { printf '%s✓%s %s\n'         "$C_GREEN"  "$C_RESET" "$1"; }
fail()       { printf '%s✗%s %s\n'         "$C_RED"    "$C_RESET" "$1"; }
warn()       { printf '%s!%s %s\n'         "$C_YELLOW" "$C_RESET" "$1"; }
dim()        { printf '%s%s%s\n'           "$C_DIM"    "$1"       "$C_RESET"; }

# ─── usage / argument parsing ────────────────────────────────────────────
usage() {
    # Print the docblock between the first and second long-fence comment lines.
    awk '
        /^# ─{20,}$/ { fences++; next }
        fences == 1   { sub(/^# ?/, ""); print }
        fences >= 2   { exit }
    ' "$0"
    exit "${1:-0}"
}

case "${1:-}" in
    -h|--help|"") usage 0 ;;
esac

DOMAINS=("$@")

# ─── prerequisites ───────────────────────────────────────────────────────
: "${PROMPT_API_DOMAIN:?Set PROMPT_API_DOMAIN before running, e.g. staging-eu.prompt.security}"
: "${PROMPT_API_KEY:?Set PROMPT_API_KEY before running (the tenant APP-ID)}"

EXT_VERSION="${EXT_VERSION:-7.1.6}"
USER_UUID="${USER_UUID:-00000000-0000-0000-0000-000000000000}"
CONFIG_FILE="${CONFIG_FILE:-/tmp/prompt-config-${PROMPT_API_DOMAIN//[^a-zA-Z0-9]/_}.json}"
FORCE="${FORCE:-0}"

# Cross-platform SHA-1 (macOS has shasum, most Linux has sha1sum)
if command -v shasum >/dev/null;  then SHA1='shasum -a 1'
elif command -v sha1sum >/dev/null; then SHA1='sha1sum'
else fail 'Need either shasum or sha1sum on PATH.'; exit 2
fi

for tool in curl jq awk grep; do
    command -v "$tool" >/dev/null || { fail "Missing required tool: $tool"; exit 2; }
done

# ─── header ──────────────────────────────────────────────────────────────
say
say "${C_BOLD}Prompt Security — GenAI domain membership check${C_RESET}"
say "${C_DIM}Backend: https://$PROMPT_API_DOMAIN${C_RESET}"
say "${C_DIM}APP-ID:  ${PROMPT_API_KEY:0:8}…${C_RESET}"
say "${C_DIM}Domains: ${DOMAINS[*]}${C_RESET}"

# ─── 1. heartbeat → CDN url ──────────────────────────────────────────────
fetch_config() {
    header "Fetching backend configuration"

    say "Step 1/2 — POST /api/extension/heartbeat"
    local hb
    hb=$(curl -fsS -X POST \
        "https://$PROMPT_API_DOMAIN/api/extension/heartbeat?APP-ID=$PROMPT_API_KEY&EXTENSION-VERSION=$EXT_VERSION" \
        -H "Content-Type: application/json" \
        -H "APP-ID: $PROMPT_API_KEY" \
        -d "{
            \"userUUID\":\"$USER_UUID\",
            \"browserName\":\"Chrome\",
            \"protocolVersion\":\"1.0\",
            \"extensionVersion\":\"$EXT_VERSION\",
            \"userAgent\":\"curl\",
            \"platformInfo\":{\"os\":\"linux\",\"arch\":\"x86_64\"},
            \"getConfig\":true,
            \"getConfigurationByTimestamp\":true,
            \"getConfigurationFromCache\":true
        }")

    local config_url
    config_url=$(echo "$hb" | jq -r '.organization.configurationUrl // empty')
    if [[ -z "$config_url" ]]; then
        fail 'Heartbeat did not return organization.configurationUrl.'
        say 'Full response (for diagnosis):'
        echo "$hb" | jq .
        exit 3
    fi
    ok 'Heartbeat returned a configurationUrl'

    say 'Step 2/2 — GET the configuration JSON (timestamps=0 forces full payload)'
    curl -fsS -G "$config_url&APP-ID=$PROMPT_API_KEY" \
        --data-urlencode "rulebase=0" \
        --data-urlencode "extensionSettings=0" \
        --data-urlencode "customGenAiAppsDomainHashes=0" \
        --data-urlencode "genAiApps=0" \
        -H "APP-ID: $PROMPT_API_KEY" \
        > "$CONFIG_FILE"
    ok "Saved config to $CONFIG_FILE"
}

if [[ "$FORCE" == "1" || ! -s "$CONFIG_FILE" ]]; then
    fetch_config
else
    header "Reusing cached configuration"
    dim "$CONFIG_FILE  (set FORCE=1 to refetch)"
fi

# ─── 2. list sizes ───────────────────────────────────────────────────────
header "Backend GenAI list sizes"

GLOBAL_LEN=$(jq -r '.genAiApps.globalDomainHashes | length' "$CONFIG_FILE")
CUSTOM_LEN=$(jq -r '.customGenAiAppsDomainHashes  | length' "$CONFIG_FILE")
FORCED_LEN=$(jq -r '.genAiApps.forcedChatUrls     | length' "$CONFIG_FILE")

printf '  %-32s %s\n' 'Global GenAI hashes'           "$GLOBAL_LEN"
printf '  %-32s %s\n' 'Tenant-custom GenAI hashes'    "$CUSTOM_LEN"
printf '  %-32s %s\n' 'Forced-chat URL patterns'      "$FORCED_LEN"

if [[ "$GLOBAL_LEN" == "0" ]]; then
    warn 'globalDomainHashes is empty — backend may not be returning the list.'
fi

# ─── 3. per-domain check ─────────────────────────────────────────────────
header "Domain membership"

# Pre-extract list members once for fast grep
GLOBAL_HASHES=$(jq -r '.genAiApps.globalDomainHashes[]' "$CONFIG_FILE")
CUSTOM_HASHES=$(jq -r '.customGenAiAppsDomainHashes[]'  "$CONFIG_FILE")

sha1() { printf '%s' "$1" | $SHA1 | awk '{print $1}'; }

ANY_MISSING=0
RESULTS=()

for domain in "${DOMAINS[@]}"; do
    h_bare=$(sha1 "$domain")
    h_www=$(sha1 "www.$domain")

    in_global=0
    in_custom=0
    grep -qFx "$h_bare" <<<"$GLOBAL_HASHES" && in_global=1 || true
    grep -qFx "$h_www"  <<<"$GLOBAL_HASHES" && in_global=1 || true
    grep -qFx "$h_bare" <<<"$CUSTOM_HASHES" && in_custom=1 || true
    grep -qFx "$h_www"  <<<"$CUSTOM_HASHES" && in_custom=1 || true

    say
    say "${C_BOLD}$domain${C_RESET}"
    dim "  sha1($domain)     = $h_bare"
    dim "  sha1(www.$domain) = $h_www"

    if (( in_global == 1 )); then
        ok  "in GLOBAL list  → extension WILL protect this domain"
        RESULTS+=("$domain	GLOBAL")
    elif (( in_custom == 1 )); then
        ok  "in CUSTOM list  → extension WILL protect this domain (tenant override)"
        RESULTS+=("$domain	CUSTOM")
    else
        fail "NOT in any list → extension will NOT show any popup on this domain"
        RESULTS+=("$domain	MISSING")
        ANY_MISSING=1
    fi
done

# ─── 4. final verdict ────────────────────────────────────────────────────
header "Verdict"

printf '%s\n' "${RESULTS[@]}" | column -t -s "$(printf '\t')" || printf '%s\n' "${RESULTS[@]}"

if (( ANY_MISSING == 1 )); then
    say
    warn 'At least one domain is NOT registered in the backend.'
    say  'To fix, choose ONE of the following:'
    say  '  • Cross-tenant: backend team adds the domain to the global GenAI catalogue'
    say  '                 (every tenant picks it up on the next config refresh).'
    say  '  • This tenant only: admin adds the domain via the customer admin console'
    say  '                      under "Custom GenAI apps".'
    say  'After the fix, re-run this script — the missing domain should flip to ✓.'
    exit 1
else
    say
    ok 'All checked domains are registered. Extension behavior is expected.'
    exit 0
fi
