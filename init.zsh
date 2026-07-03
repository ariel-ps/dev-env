# dev-env loader — source from ~/.zshrc:
#   source ~/Documents/projects/dev-env/init.zsh
#
# Loads persistent shell settings from settings/*.zsh, then every *.sh under
# scripts/<profile>/ so each subprofile can drop in helpers without touching
# this file.

DEV_ENV_ROOT="${0:A:h}"

autoload -Uz compinit && compinit

# Source settings directly because shell options, such as history behavior, must
# persist after this loader returns.
for setting in "$DEV_ENV_ROOT"/settings/*.zsh(N); do
  [ -r "$setting" ] && source "$setting"
done

# Source each helper in a function with `emulate -L zsh` so that any options a
# helper sets (set -e / set -u / pipefail) stay LOCAL and are reverted on return.
# This prevents a stray executable-style script from leaking errexit into your
# interactive shell (which would close the session on the first failing command,
# e.g. over SSH). Functions, aliases and exports defined by the helper persist.
_dev_env_source() { emulate -L zsh; source "$1"; }

for script in "$DEV_ENV_ROOT"/scripts/*/*.sh; do
  [ -r "$script" ] && _dev_env_source "$script"
done

unset -f _dev_env_source
unset setting script
