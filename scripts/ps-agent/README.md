# ps-agent dev helpers

Shell helpers for working with the Prompt Security agent on macOS — managing
the local install, and talking to the tenant API the agent uses.

Auto-loaded by the dev-env loader: `~/.zshrc` sources
`~/Documents/projects/dev-env/init.zsh`, which globs `scripts/*/*.sh` and
picks up every helper in this folder. Open a new shell to refresh.

| File | What it gives you |
|---|---|
| `pa.sh` | `pa` — drive the local agent (start/stop/logs/edit config) |
| `pa-api.sh` | `pa-api` — call the tenant API the agent itself uses |
| `reset-plist.sh` | `reset-plist` — wipe Safari extension plists (user + MDM) |
| `bin/check-domain-in-genai-list.sh` | Standalone GenAI domain checker; on PATH after load |
| `bin/verify-maintenance-token.sh` | Standalone maintenance token decoder/verifier; on PATH after load |

## `pa` — local agent control

```
pa status      sudo prompt_agent status
pa start       launchctl load   /Library/LaunchDaemons/com.prompt.service.plist
pa stop        launchctl unload …
pa restart     stop + start                    (also: par)
pa logs        tail -f /Users/Shared/.prompt_security/service_logs.log
pa hardening-status
               clean hardening status + guard version/build/sha
pa hardening-logs
               cat /Users/Shared/.prompt_security/hardening_audit.log
pa logout      sudo prompt_agent logout
pa uninstall   sudo prompt_agent uninstall
pa edit        unhide + chmod +w config.toml, open in nano,
               re-hide + chflags schg on exit (even on Ctrl-C)
```

## `pa-api` — tenant API

Same endpoints the agent calls. Credentials are auto-resolved in this order
(matches `src/common/config.py:94 get_platform_config`):

1. Env: `$PROMPT_API_DOMAIN` + `$PROMPT_API_KEY` (overrides everything)
2. MDM plist: `/Library/Managed Preferences/com.prompt.security.agent.plist`
3. Agent config: `/Library/Application Support/Prompt/config.toml`
   (chflags-hidden — needs `sudo`, you'll be prompted once per shell)

```
pa-api whoami                show resolved domain + masked app-id + source
pa-api env                   eval-friendly export lines for PROMPT_API_*
pa-api get-apps              GET /api/protect-native-apps/get_apps
pa-api get-secrets [domain]  GET /api/protect-native-apps/get_secrets_policy
pa-api get-policy <url> [email]  POST /api/employee/evaluate-rule (per-domain policy)
pa-api heartbeat             POST /api/protect-native-apps/heartbeat
pa-api apps-summary          histogram of apps (count → name)
pa-api apps-by-name <app>    URL patterns mapped to a given app
pa-api match <url>           replicates should_inspect_app(url) client-side
pa-api genai-check <dom>...  wraps bin/check-domain-in-genai-list.sh
pa-api verify-maintenance-token <token>
                              decode + verify a maintenance token
pa-api curl <path> [args]    authed curl to https://${domain}<path>
```

Add `--raw` after the subcommand to skip jq formatting (or set `PA_API_RAW=1`).

### Common recipes

```bash
# Quick sanity check that creds resolve
pa-api whoami

# What's in the live INSPECT_URLS_MAP for this tenant?
pa-api apps-summary

# Show every URL the tenant maps to GitHub Copilot
pa-api apps-by-name "GitHub Copilot"

# Find which app the agent would classify a URL as
pa-api match https://api.githubcopilot.com/chat/completions

# Fetch the rulebase-v2 policy for a URL (action / popup / regexPolicy / etc.)
pa-api get-policy https://chat.openai.com/backend-api/conversation
pa-api get-policy https://claude.ai/api/organizations/x/chat_conversations alice@acme.com

# Hit any other tenant endpoint (passes through to curl)
pa-api curl /api/protect-native-apps/heartbeat -X POST -d '{"configTimestamps":{}}'

# Confirm a domain is in the GenAI list (uses bin/ helper, creds pre-injected)
pa-api genai-check chat.openai.com claude.ai stepfun.ai

# Decode a maintenance token and verify it against the tenant selected by
# the installed agent API key
pa-api verify-maintenance-token "$TOKEN"

# Export creds for another tool / one-off curl
eval "$(pa-api env)"
curl -fsS "https://$PROMPT_API_DOMAIN/api/protect-native-apps/get_apps" \
  -H "app-id: $PROMPT_API_KEY" | jq 'to_entries[:5]'
```

## `reset-plist` — Safari extension plist reset

Used when debugging the Safari extension's hidden API-key inputs / cached
configuration. Wipes the user-side preference plists and (optionally) the
MDM-pushed one so the extension boots fresh.

```
reset-plist user     delete user prefs + MDM plist (default)
reset-plist mdm-off  move MDM plist → /tmp backup (re-pushed by JumpCloud later)
reset-plist mdm-on   restore the MDM plist from /tmp backup
reset-plist all      user + mdm-off
reset-plist status   show which plists currently exist
```

Quit Safari fully (⌘Q) after wiping for the change to take effect.

## `bin/check-domain-in-genai-list.sh`

Standalone bash script (also runnable directly — `bin/` is on PATH).
Verifies whether a domain is registered in the backend's GenAI catalogue
(the SHA-1-hash list the browser extension uses). Reads `$PROMPT_API_DOMAIN`
+ `$PROMPT_API_KEY` from the environment.

`pa-api genai-check` is the easy way to invoke it — it loads creds first.

## `bin/verify-maintenance-token.sh`

Standalone bash script (also runnable directly — `bin/` is on PATH).
Takes only the token, prints the decoded token JSON, then verifies it via
`POST /api/agent/maintenance/v1/verify` using the same agent domain/API key
resolution as `pa-api`.

```bash
verify-maintenance-token.sh "$TOKEN"
# or
pa-api verify-maintenance-token "$TOKEN"
```

## Tab completion

`compdef _pa pa` and `compdef _pa_api pa-api` are registered in the helper
files. Subcommand completion works out of the box.

## Troubleshooting

- **"pa-api: no credentials found"** — neither env, MDM plist, nor
  `config.toml` resolved a domain. Set `PROMPT_API_DOMAIN` /
  `PROMPT_API_KEY`, or check that the agent is installed and `pa edit`
  shows a populated `[app]` section.
- **`sudo` prompt every time** — the `config.toml` fallback uses `sudo cat`
  because the file is chflags-hidden and root-owned. Either export
  `PROMPT_API_*` once at the start of your session, or run `pa-api whoami`
  early so subsequent calls in the same shell reuse the cached resolution.
- **Helper not picked up** — confirm `~/.zshrc` sources
  `~/Documents/projects/dev-env/init.zsh` and that the file lives at
  `scripts/ps-agent/*.sh` (the loader's glob is one level deep).
