#!/bin/sh
get_script_dir() { case "${0}" in *"/"*) d="${0%/*}";; *) d=.;; esac; CDPATH="" cd -- "${d}" && pwd -P; }
try_lib_at() { f="${1}/libshell.sh"; [ -r "${f}" ] && . "${f}" 2>/dev/null; };_THIS_DIR_="$(get_script_dir)"
try_lib_at "${_THIS_DIR_}" || try_lib_at "${_THIS_DIR_}/common" || try_lib_at "${_THIS_DIR_}/.." || \
try_lib_at "${_THIS_DIR_}/../common" || { echo "Error loading library."; exit 1; }


_SERVICE_NAME_="ipt2socks"
_SERVICE_NAME_CAP_="Ipt2socks"
_SERVICE_EXEC_="ipt2socks"
_SERVICE_TITLE_="${_SERVICE_NAME_CAP_} Service"
_SERVICE_DIR_="/opt/ipt2socks"
_RUN_SCRIPT_="${_SERVICE_DIR_}/run-${_SERVICE_NAME_}.sh"
_INSTALL_LOG_="/tmp/install-${_SERVICE_NAME_}.log"

# Default runtime parameters (overridden by ipt2socks.conf if present)
SOCKS5_ADDR="127.0.0.1"
SOCKS5_PORT="10890"
LISTEN_ADDR="0.0.0.0"
LISTEN_PORT="10898"
EXTRA_ARGS="-R -4"

# Line Feed character, used to append newlines without raw line breaks in code.
_LF_=$(printf '\n')


#
# Detect init system
#
if [ -d /run/systemd/system ]; then
    _INIT_SYSTEM_="systemd"
elif [ -f /etc/rc.common ]; then
    _INIT_SYSTEM_="procd"
else
    _INIT_SYSTEM_="none"
fi
echo "Detected init system: ${_INIT_SYSTEM_}"


#
# Config parsing
#
_CONF_FILE_=""
if [ -f "/opt/ipt2socks/ipt2socks.conf" ]; then
    _CONF_FILE_="/opt/ipt2socks/ipt2socks.conf"
elif [ -f "/opt/configs/ipt2socks.conf" ]; then
    _CONF_FILE_="/opt/configs/ipt2socks.conf"
fi

_CONF_FOUND_=0
case "${_CONF_FILE_}" in "");; *)
    _CONF_FOUND_=1
    echo "Found config file: ${_CONF_FILE_}"

    # Reset to defaults before parsing, so missing fields fall back correctly
    SOCKS5_ADDR="127.0.0.1"
    SOCKS5_PORT="10890"
    LISTEN_ADDR="0.0.0.0"
    LISTEN_PORT="10898"

    _CONF_CONTENT_=$(cat "${_CONF_FILE_}")
    case "${_CONF_CONTENT_}" in *"${_LF_}"*);; *)
        _CONF_CONTENT_="${_CONF_CONTENT_}${_LF_}";;
    esac

    while IFS= read -r _cline_; do
        _cline_="${_cline_%"${symbol_crlf}"}"
        case "${_cline_}" in ""|"#"*) continue;; *=*);; *) continue;; esac

        _left_="${_cline_%%=*}"
        _right_="${_cline_#*=}"

        # Parse inbound (left side): [host:]port
        case "${_left_}" in
            *:*)
                _lhost_="${_left_%%:*}"
                _lport_="${_left_##*:}"
                ;;
            *)
                _lhost_=""
                _lport_="${_left_}"
                ;;
        esac
        case "${_lhost_}" in "") LISTEN_ADDR="0.0.0.0";; *) LISTEN_ADDR="${_lhost_}";; esac
        case "${_lport_}" in "") LISTEN_PORT="10898";; *) LISTEN_PORT="${_lport_}";; esac

        # Parse outbound (right side): [host:]port
        case "${_right_}" in
            *:*)
                _rhost_="${_right_%%:*}"
                _rport_="${_right_##*:}"
                ;;
            *)
                _rhost_=""
                _rport_="${_right_}"
                ;;
        esac
        case "${_rhost_}" in "") SOCKS5_ADDR="127.0.0.1";; *) SOCKS5_ADDR="${_rhost_}";; esac
        case "${_rport_}" in "") SOCKS5_PORT="10890";; *) SOCKS5_PORT="${_rport_}";; esac

        break # Assume only the first valid line matters
    done <<EOF
${_CONF_CONTENT_}
EOF
    ;;
esac


#
# Architecture mapping
#
url_decode() {
    _ud_str_="$1"
    _ud_out_=""
    while :; do
        case "${_ud_str_}" in
        *"%40"*)
            _ud_out_="${_ud_out_}${_ud_str_%%"%40"*}@"
            _ud_str_="${_ud_str_#*"%40"}"
            ;;
        *"%2B"*)
            _ud_out_="${_ud_out_}${_ud_str_%%"%2B"*}+"
            _ud_str_="${_ud_str_#*"%2B"}"
            ;;
        *)
            _ud_out_="${_ud_out_}${_ud_str_}"
            break
            ;;
        esac
    done
    printf '%s' "${_ud_out_}"
}

map_arch_to_asset() {
    case "$1" in
    *aarch64*|*arm64*)
        echo "ipt2socks@aarch64-linux-musl@generic+v8a";;
    *x86_64*|*amd64*)
        echo "ipt2socks@x86_64-linux-musl@x86_64";;
    *i386*|*i486*|*i586*|*i686*)
        echo "ipt2socks@i386-linux-musl@i686";;
    *mips64el*)
        echo "ipt2socks@mips64el-linux-musl@mips64";;
    *mips64*)
        echo "ipt2socks@mips64-linux-musl@mips64";;
    *mipsel*)
        echo "ipt2socks@mipsel-linux-musl@mips32";;
    *mips*)
        echo "ipt2socks@mips-linux-musl@mips32";;
    *armv7*|*arm_cortex*)
        echo "ipt2socks@arm-linux-musleabihf@generic+v7a";;
    *armv6*)
        echo "ipt2socks@arm-linux-musleabi@generic+v6+soft_float";;
    *armv5*)
        echo "ipt2socks@arm-linux-musleabi@generic+v5t+soft_float";;
    *arm*)
        echo "ipt2socks@arm-linux-musleabihf@generic+v7a";;
    *)
        echo "";;
    esac
}


#
# Find and download latest release
#
_ASSET_PREFIX_="$(map_arch_to_asset "${os_arch_name}")"
case "${_ASSET_PREFIX_}" in "")
    echo "Unsupported architecture: ${os_arch_name}. No matching ipt2socks release asset."
    exit 1
    ;;
esac
echo "Mapping ${os_arch_name} -> ${_ASSET_PREFIX_}..."

mkdir -p "${_SERVICE_DIR_}"
: >"${_INSTALL_LOG_}"

echo "Downloading latest ${_SERVICE_NAME_} release..."
_FILE_URLS_=""
get_github_latest_release_urls_list "zfl9/${_SERVICE_NAME_}" "_FILE_URLS_"

case "${_FILE_URLS_}" in "")
    echo "Error: Failed to fetch release URLs from GitHub API."
    exit 1
    ;;
esac

case "${_FILE_URLS_}" in *"${_LF_}"*);; *)
    _FILE_URLS_="${_FILE_URLS_}${_LF_}";;
esac

_FILE_URL_=""
_DECODED_URLS_=""

while IFS= read -r _line_; do
    _line_="${_line_%"${symbol_crlf}"}"
    case "${_line_}" in "") continue;; esac
    _decoded_=$(url_decode "${_line_}")
    _DECODED_URLS_="${_DECODED_URLS_}${_decoded_}${_LF_}"
    case "${_decoded_}" in *"${_ASSET_PREFIX_}")
        case "${_FILE_URL_}" in "") _FILE_URL_="${_line_}";; esac
        ;;
    esac
done <<EOF
${_FILE_URLS_}
EOF

case "${_FILE_URL_}" in "")
    echo "No release asset found matching suffix '${_ASSET_PREFIX_}'."
    echo "Available assets in the latest release:"
    while IFS= read -r _line_; do
        echo "  - ${_line_##*/}"
    done <<EOF
${_DECODED_URLS_}
EOF
    exit 1
    ;;
esac

_FILE_NAME_="${_FILE_URL_##*/}"
_FILE_NAME_=$(url_decode "${_FILE_NAME_}")

get_content "${_FILE_URL_}" "/tmp/${_FILE_NAME_}"
case $? in 0);; *)
    echo "Error downloading ${_FILE_URL_}, exiting."
    exit 1
    ;;
esac

if ! [ -s "/tmp/${_FILE_NAME_}" ]; then
    echo "Downloaded file /tmp/${_FILE_NAME_} is empty, exiting."
    exit 1
fi
echo "Successfully downloaded ${_FILE_NAME_}."


#
# Install binary
#
if [ -x "${_SERVICE_DIR_}/${_SERVICE_EXEC_}" ]; then
    mv -f "${_SERVICE_DIR_}/${_SERVICE_EXEC_}" "${_SERVICE_DIR_}/${_SERVICE_EXEC_}.old"
fi
if ! cp -f "/tmp/${_FILE_NAME_}" "${_SERVICE_DIR_}/${_SERVICE_EXEC_}"; then
    echo "Error copying binary to ${_SERVICE_DIR_}/${_SERVICE_EXEC_}, exiting."
    exit 1
fi
chmod +x "${_SERVICE_DIR_}/${_SERVICE_EXEC_}"
"${_SERVICE_DIR_}/${_SERVICE_EXEC_}" --help >/dev/null 2>&1
case $? in 0);; *)
    echo "Installed ${_SERVICE_NAME_} executable not working, exiting."
    exit 1
    ;;
esac
echo "Successfully installed ${_SERVICE_NAME_} to ${_SERVICE_DIR_}/${_SERVICE_EXEC_}."


#
# Generate or update run script
#
if [ "${_CONF_FOUND_}" = "1" ] || [ ! -f "${_RUN_SCRIPT_}" ]; then
    _OLD_EXTRA_ARGS_="${EXTRA_ARGS}"
    if [ -f "${_RUN_SCRIPT_}" ]; then
        _tmp_args_=""
        _RUN_CONTENT_=$(cat "${_RUN_SCRIPT_}")
        case "${_RUN_CONTENT_}" in *"${_LF_}"*);; *)
            _RUN_CONTENT_="${_RUN_CONTENT_}${_LF_}";;
        esac
        while IFS= read -r _rline_; do
            _rline_="${_rline_%"${symbol_crlf}"}"
            case "${_rline_}" in
            *"-s "*|*"-p "*|*"-b "*|*"-l "*|*"exec "*|*"\\"*|"#!/bin/sh"|"")
                ;;
            *)
                # Trim leading/trailing spaces to avoid double-spacing in the new file
                _rline_="${_rline_#"${_rline_%%[![:space:]]*}"}"
                _rline_="${_rline_%"${_rline_##*[![:space:]]}"}"
                case "${_rline_}" in "");; *) _tmp_args_="${_rline_}";; esac
                ;;
            esac
        done <<EOF
${_RUN_CONTENT_}
EOF
        case "${_tmp_args_}" in "");; *)
            _OLD_EXTRA_ARGS_="${_tmp_args_}";;
        esac
    fi

    cat >"${_RUN_SCRIPT_}" <<EOF
#!/bin/sh
exec "${_SERVICE_DIR_}/${_SERVICE_EXEC_}" \\
    -s "${SOCKS5_ADDR}" \\
    -p "${SOCKS5_PORT}" \\
    -b "${LISTEN_ADDR}" \\
    -l "${LISTEN_PORT}" \\
    ${_OLD_EXTRA_ARGS_}
EOF
    chmod +x "${_RUN_SCRIPT_}"
    echo "Created/Updated run script: ${_RUN_SCRIPT_}"
else
    echo "Keeping existing run script: ${_RUN_SCRIPT_}"
fi


#
# Generate init/systemd wrappers and (re)start service
#
case "${_INIT_SYSTEM_}" in
"systemd")
    cat >"${_SERVICE_DIR_}/${_SERVICE_NAME_}.service" <<EOF
[Unit]
Description=${_SERVICE_TITLE_}
Documentation=https://github.com/zfl9/${_SERVICE_NAME_}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${_RUN_SCRIPT_}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /etc/systemd/system
    ln -sf "${_SERVICE_DIR_}/${_SERVICE_NAME_}.service" "/etc/systemd/system/${_SERVICE_NAME_}.service"
    systemctl daemon-reload
    systemctl enable "${_SERVICE_NAME_}"
    systemctl restart "${_SERVICE_NAME_}"
    ;;
*)
    cat >"${_SERVICE_DIR_}/${_SERVICE_NAME_}.init" <<EOF
#!/bin/sh /etc/rc.common

START=95
STOP=10
USE_PROCD=1

RUN=${_RUN_SCRIPT_}

start_service() {
    [ -x "\$RUN" ] || return 1
    procd_open_instance
    procd_set_param command "\$RUN"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
    chmod +x "${_SERVICE_DIR_}/${_SERVICE_NAME_}.init"

    case "${_INIT_SYSTEM_}" in
    "procd")
        mkdir -p /etc/init.d
        ln -sf "${_SERVICE_DIR_}/${_SERVICE_NAME_}.init" "/etc/init.d/${_SERVICE_NAME_}"
        /etc/init.d/${_SERVICE_NAME_} enable
        /etc/init.d/${_SERVICE_NAME_} restart 2>/dev/null || /etc/init.d/${_SERVICE_NAME_} start
        ;;
    *)
        echo "No supported init system detected; run ${_RUN_SCRIPT_} manually."
        ;;
    esac
esac
echo "${_SERVICE_NAME_CAP_} was (re)installed and started."

rm -f "/tmp/${_FILE_NAME_}" 2>/dev/null
cmp -s "${_SERVICE_DIR_}/${_SERVICE_EXEC_}" "${_SERVICE_DIR_}/${_SERVICE_EXEC_}.old" >/dev/null 2>&1 \
    && rm -f "${_SERVICE_DIR_}/${_SERVICE_EXEC_}.old"
