#!/usr/bin/env zsh
# tcc profile — macOS TCC.db inspection helpers.
#
# Adds scripts/tcc/bin to PATH so `tcc-audit` is callable by name. tcc-audit is
# a read-only inspector for the Transparency/Consent/Control database (what each
# app is allowed to do: camera, mic, Full Disk Access, Accessibility, ...).

_TCC_BIN_DIR="${0:A:h}/bin"
if [[ -d "$_TCC_BIN_DIR" && ":$PATH:" != *":$_TCC_BIN_DIR:"* ]]; then
  path=("$_TCC_BIN_DIR" $path)
fi
unset _TCC_BIN_DIR
