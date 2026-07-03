# Persistent zsh history settings.
#
# Keep as much command history as practical and preserve timestamps. This is
# intentionally not sourced through the helper wrapper in init.zsh because
# shell options must persist in the interactive shell.

HISTFILE="${DEV_ENV_HISTFILE:-$HOME/.zsh_history}"
HISTSIZE="${DEV_ENV_HISTSIZE:-100000000}"
SAVEHIST="${DEV_ENV_SAVEHIST:-100000000}"

mkdir -p "${HISTFILE:h}"

setopt EXTENDED_HISTORY
setopt APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_FCNTL_LOCK
setopt HIST_SAVE_BY_COPY

unsetopt HIST_IGNORE_DUPS
unsetopt HIST_IGNORE_ALL_DUPS
unsetopt HIST_IGNORE_SPACE
unsetopt HIST_SAVE_NO_DUPS
unsetopt HIST_FIND_NO_DUPS
unsetopt HIST_REDUCE_BLANKS
unsetopt HIST_EXPIRE_DUPS_FIRST
unsetopt HIST_NO_FUNCTIONS
unsetopt HIST_NO_STORE
