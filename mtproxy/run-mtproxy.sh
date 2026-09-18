#!/bin/sh

get_script_dir() { case "$0" in */*) d="${0%/*}" ;; *) d=. ;; esac; CDPATH= cd -- "$d" && pwd -P; }
#_MTPROXY_DIR_="$(get_script_dir)"
_MTPROXY_DIR_=/opt/mtproxy
_TELEGO_="$(command -v ${_MTPROXY_DIR_}/telego)"
_TELEPROXY_="$(command -v ${_MTPROXY_DIR_}/teleproxy)"
_DEFAULT_INPORT_=8443

_RC_=1
_SOURCE_="/opt/mtproxy/mtproxy.conf"
if ! [ -s "${_SOURCE_}" ]; then
	_SOURCE_="/opt/configs/mtproxy.conf"
fi

if [ -n "${_TELEGO_}" ]; then
	_CONFIG_="/opt/mtproxy/telego.conf"
	_TMP_FILE_=$(mktemp)
	counter=1
	while read -r line; do
		line="${line%%#*}"
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		case "${line}" in "") continue;; esac
		username="${line%=*}"
		secret="${line##*=}"
		username="${username#"${username%%[![:space:]]*}"}"
		username="${username%"${username##*[![:space:]]}"}"
		secret="${secret#"${secret%%[![:space:]]*}"}"
		secret="${secret%"${secret##*[![:space:]]}"}"
		case "${line}" in
		*"="*)
			echo "${username} = \"${secret}\"";;
		*)
			echo "user${counter} = \"${secret}\"";;
		esac
		counter=$((counter + 1))
	done <"${_SOURCE_}" >"${_TMP_FILE_}"
	if [ -s "${_TMP_FILE_}" ]; then
		echo >>"${_TMP_FILE_}"
		sed -i '/\[secrets\]/,/^\[/ { /^\[/!d; }' "${_CONFIG_}"
		sed -i "/\[secrets\]/r ${_TMP_FILE_}" "${_CONFIG_}"
		rm "${_TMP_FILE_}"
		_RC_=0
		exec "${_TELEGO_}" run --config=${_MTPROXY_DIR_}/telego.conf
	fi
else
	_SECRET_=
	while read -r line; do
		line="${line%%#*}"
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		case "${line}" in "") continue;; esac
		username="${line%=*}"
		secret="${line##*=}"
		username="${username#"${username%%[![:space:]]*}"}"
		username="${username%"${username##*[![:space:]]}"}"
		secret="${secret#"${secret%%[![:space:]]*}"}"
		secret="${secret%"${secret##*[![:space:]]}"}"
		_SECRET_ = "${secret}"
		break
	done <"${_SOURCE_}"
	if [ -s "${_TMP_FILE_}" ]; then
		echo >>"${_TMP_FILE_}"
		_RC_=0
		if [ -n "${_TELEPROXY_}" ]; then
			exec "${_TELEPROXY_}" -u nobody -M 1 \
				-S ${_SECRET_} \
				--aes-pwd proxy-secret proxy-multi.conf \
				--address 0.0.0.0 -p 8888 -H ${_DEFAULT_INPORT_} \
				--direct --socks5 socks5://127.0.0.1:1089
		else
			_PROXYCHAINS_="$(command -v proxychains4)"
			exec ${_PROXYCHAINS_}${_PROXYCHAINS_:+ -f ${_MTPROXY_DIR_}/proxychains4.conf} \
				${_MTPROXY_DIR_}/mtproto-proxy -u nobody -M 1 \
					-S ${_SECRET_} \
					--aes-pwd proxy-secret proxy-multi.conf \
					--address 0.0.0.0 -p 8888 -H ${_DEFAULT_INPORT_}
		fi
	fi
fi

case ${_RC_} in 0);; *)
	echo "No secrets found in \"${_SOURCE_}\"."
esac
