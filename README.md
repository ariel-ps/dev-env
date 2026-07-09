# dev-env

Personal shell environment — small, sourced helpers organized by "profile"
(one folder per project / domain). One loader, drop-in additions.

## Install

Add to `~/.zshrc`:

```sh
source ~/Documents/projects/dev-env/init.zsh
```

That's it. Open a new shell.

## Layout

```
init.zsh                        # loader — globs scripts/*/*.sh and sources them
scripts/
  ps-agent/                     # one profile = one folder
    README.md                   # profile-specific docs
    pa.sh                       # → defines `pa` function
    pa-api.sh                   # → defines `pa-api` function
    bin/                        # not sourced; added to $PATH by the helper
      check-domain-in-genai-list.sh
```

## How it loads

`init.zsh`:

```sh
for script in "$DEV_ENV_ROOT"/scripts/*/*.sh; do
  [ -r "$script" ] && source "$script"
done
```

- Only `scripts/<profile>/*.sh` is sourced — one level deep.
- `scripts/<profile>/bin/` is **not** sourced (the glob doesn't reach it).
  Put real executable scripts there and have your profile `.sh` prepend
  `bin/` to `$PATH` if you want them callable by name.

## Profiles

| Profile | Docs | Provides |
|---|---|---|
| `ai` | — | `claude-danger`, `codex-danger`, `cl4r1t4s-sync` (cache leaked prompts to `~/.cache/CL4R1T4S`), `claude-persona` (launch claude in danger mode with a picked system prompt) |
| `alert` | — | `gilfoyle` (audio alert), `alert8` (8-bit alert), `psay` (text-to-speech) |
| `ps-agent` | [scripts/ps-agent/README.md](scripts/ps-agent/README.md) | `pa` (local agent control), `pa-api` (tenant API), `check-domain-in-genai-list.sh` |
| `k8s` | — | `kubectl` aliases: `k`, `kpod`, `ksvc`, `ksts`, `kdep`, `kns`, `klogf`, `kexec`, … |
| `docker` | — | `hermes-webui` (Hermes WebUI in Docker), `openspec-ui` (OpenSpec UI dashboard in Docker) |
| `utils` | — | `mw-start`/`mw-stop` (mitmweb proxy + web UI), `mitm-to-jsonl` (convert flows to JSONL), `detect-msg-format`, `js-inspect`, `py-inspect` |

The `alert` profile assigns each zsh session an `ALERT_SESSION_ID` and
generates a matching 8-bit WAV at `ALERT8_SESSION_SOUND`, which `alert8` plays.

## Adding a new profile

1. `mkdir scripts/<name>`
2. Drop a `<thing>.sh` file in it that defines shell functions
   (don't write top-level side effects beyond function/alias/compdef
   definitions — the file is sourced on every shell startup).
3. Optionally `mkdir scripts/<name>/bin` for standalone executables, and
   prepend that dir to `$PATH` from your `.sh`.
4. Optionally add `scripts/<name>/README.md` to document it.

Open a new shell — it's live. No edits to `init.zsh` needed.

## Conventions

- Helpers should namespace their function names by profile prefix
  (`pa`, `pa-api`, …) to avoid collisions across profiles.
- Use `compdef` for zsh completion when a helper has subcommands.
- Keep sourced files side-effect-free at top level — only function
  definitions, aliases, `compdef` calls, and at most one `PATH` prepend
  guarded against duplicate entries.
