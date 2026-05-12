# dev-env loader — source from ~/.zshrc:
#   source ~/Documents/projects/dev-env/init.zsh
#
# Loads every *.sh under scripts/<profile>/ so each subprofile (ps-agent, ...)
# can drop in helpers without touching this file.

DEV_ENV_ROOT="${0:A:h}"

autoload -Uz compinit && compinit

for script in "$DEV_ENV_ROOT"/scripts/*/*.sh; do
  [ -r "$script" ] && source "$script"
done

unset script
