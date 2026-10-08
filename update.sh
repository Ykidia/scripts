#!/bin/bash
get_script_dir() { case "${0}" in *"/"*) d="${0%/*}";; *) d=.;; esac; CDPATH="" cd -- "${d}" && pwd -P; }
try_lib_at() { f="${1}/libshell.sh"; [ -r "${f}" ] && . "${f}" 2>/dev/null; }; _THIS_DIR_="$(get_script_dir)"


git -C "${_THIS_DIR_}" pull --recurse-submodules && git -C "${_THIS_DIR_}" submodule update --init --remote --recursive
