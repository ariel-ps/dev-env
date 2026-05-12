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
| `ps-agent` | [scripts/ps-agent/README.md](scripts/ps-agent/README.md) | `pa` (local agent control), `pa-api` (tenant API), `check-domain-in-genai-list.sh` |

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
