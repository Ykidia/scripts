#!/bin/sh

get_script_dir() { case "${0}" in *"/"*) d="${0%/*}";; *) d=.;; esac; CDPATH="" cd -- "${d}" && pwd -P; }
_THIS_DIR_="$(get_script_dir)"

for installer in $(ls ${_THIS_DIR_}/*/install-*.sh); do
    [ "$(readlink -f "${0}")" != "$(readlink -f "${installer}")" ] && echo "${installer}"
done
