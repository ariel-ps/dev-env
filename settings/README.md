# Settings

Files in this directory are sourced directly by `init.zsh`.

Use this directory for persistent shell settings that must remain active after
the loader returns. Normal helper scripts should stay under `scripts/<profile>/`.

## History

`history.zsh` configures zsh to keep a large command history, write commands
incrementally, share history across terminals, and preserve timestamps.

You can override the defaults before sourcing `init.zsh`:

```zsh
export DEV_ENV_HISTFILE="$HOME/.zsh_history"
export DEV_ENV_HISTSIZE=100000000
export DEV_ENV_SAVEHIST=100000000
```

This records commands exactly as typed, including commands that start with a
space. Avoid typing secrets directly into the shell.
