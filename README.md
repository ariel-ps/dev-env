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
| `ai` | — | `claude-danger`, `codex-danger`, `cl4r1t4s-sync` (cache leaked prompts to `~/.cache/CL4R1T4S`), `pentestgpt-sync` (cache PentestGPT to `${XDG_CACHE_HOME:-~/.cache}/PentestGPT`), `claude-persona` (launch claude in danger mode with a picked system prompt) |
| `alert` | — | `gilfoyle` (audio alert), `alert8` (procedural 8-bit alert), `alert8play` (random real 8-bit game sound by project), `alert8-sync` (download sound packs to cache), `psay` (text-to-speech) |
| `ps-agent` | [scripts/ps-agent/README.md](scripts/ps-agent/README.md) | `pa` (local agent control), `pa-api` (tenant API), `check-domain-in-genai-list.sh` |
| `k8s` | — | `kubectl` aliases: `k`, `kpod`, `ksvc`, `ksts`, `kdep`, `kns`, `klogf`, `kexec`, … |
| `docker` | — | `hermes-webui` (Hermes WebUI in Docker), `openspec-ui` (OpenSpec UI dashboard in Docker) |
| `utils` | — | `mw-start`/`mw-stop` (mitmweb proxy + web UI), `mitm-to-jsonl` (convert flows to JSONL), `detect-msg-format`, `js-inspect`, `py-inspect` |
| `tcc` | — | `tcc-audit` (read-only inspector for the macOS TCC.db — decodes what each app is allowed/denied: camera, mic, Full Disk Access, Accessibility, ...) |

The `alert` profile assigns each zsh session an `ALERT_SESSION_ID` and
generates a matching 8-bit WAV at `ALERT8_SESSION_SOUND`, which `alert8` plays.

`alert8play` goes further: it plays a random **real** 8-bit game sound chosen by
the project the shell is in. Run `alert8-sync` once to download sound packs from
archive.org into `${XDG_CACHE_HOME:-~/.cache}/dev-env-alert/sounds/<game>/`
(nothing is bundled in the repo). Then `alert8play` detects the profile from
`$PWD` (git repo name or path) and plays a random clip from the mapped game:

| project / profile | game |
|---|---|
| `ps-agent` (incl. mac-guard) | Mario |
| `ps-platform` / frontend | Mario vs. Donkey Kong |
| `aws-vpn` | NES Metal Gear |
| `k8s` | Sonic Advance 2 |
| `docker` | Kirby |
| `git` | Punch-Out |
| anything else | Mario (default) |

The downloaded clips are game rips — fine for personal use, not redistribution,
so they live in the cache and are never committed.

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
