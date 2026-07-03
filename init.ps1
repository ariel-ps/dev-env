# dev-env loader — dot-source from $PROFILE:
#   . "$HOME\Documents\projects\dev-env\init.ps1"
#
# Loads every *.ps1 under scripts/<profile>/ (mirrors init.zsh for Windows).

$DEV_ENV_ROOT = $PSScriptRoot

Get-ChildItem "$DEV_ENV_ROOT\scripts\*\*.ps1" | ForEach-Object { . $_.FullName }
