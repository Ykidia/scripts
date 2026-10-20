#!/bin/sh
get_script_dir() { case "${0}" in *"/"*) d="${0%/*}";; *) d=.;; esac; CDPATH="" cd -- "${d}" && pwd -P; }
try_lib_at() { f="${1}/libshell.sh"; [ -r "${f}" ] && . "${f}" 2>/dev/null; }
_THIS_DIR_="$(get_script_dir)"
try_lib_at "${_THIS_DIR_}" || try_lib_at "${_THIS_DIR_}/common" || try_lib_at "${_THIS_DIR_}/.." || \
try_lib_at "${_THIS_DIR_}/../common" || { echo "Error loading library."; exit 1; }

_SERVICE_NAME_="ipt2socks"
_SERVICE_NAME_CAP_="Ipt2socks"
_SERVICE_EXEC_="ipt2socks"
_SERVICE_TITLE_="${_SERVICE_NAME_CAP_} Service"
_SERVICE_DIR_="/opt/ipt2socks"
_RUN_SCRIPT_="${_SERVICE_DIR_}/run-${_SERVICE_NAME_}.sh"
_INSTALL_LOG_="/tmp/install-${_SERVICE_NAME_}.log"

# Runtime parameters used to generate run-*.sh on first install.
SOCKS5_ADDR="127.0.0.1"
SOCKS5_PORT="10890"
LISTEN_ADDR="0.0.0.0"
LISTEN_PORT="10898"
EXTRA_ARGS="-R -4"

# Detect init system
if [ -d /run/systemd/system ]; then
    _INIT_SYSTEM_="systemd"
elif [ -f /etc/rc.common ]; then
    _INIT_SYSTEM_="procd"
else
    _INIT_SYSTEM_="none"
fi
echo "Detected init system: ${_INIT_SYSTEM_}"

# Map detected architecture to the exact release asset filename suffix.
map_arch_to_asset() {
    case "$1" in
        *aarch64*|*arm64*)
            echo "ipt2socks@aarch64-linux-musl@generic+v8a" ;;
        *x86_64*|*amd64*)
            echo "ipt2socks@x86_64-linux-musl@x86_64" ;;
        *i386*|*i486*|*i586*|*i686*)
            echo "ipt2socks@i386-linux-musl@i686" ;;
        *mips64el*)
            echo "ipt2socks@mips64el-linux-musl@mips64" ;;
        *mips64*)
            echo "ipt2socks@mips64-linux-musl@mips64" ;;
        *mipsel*)
            echo "ipt2socks@mipsel-linux-musl@mips32" ;;
        *mips*)
            echo "ipt2socks@mips-linux-musl@mips32" ;;
        *armv7*|*arm_cortex*)
            echo "ipt2socks@arm-linux-musleabihf@generic+v7a" ;;
        *armv6*)
            echo "ipt2socks@arm-linux-musleabi@generic+v6+soft_float" ;;
        *armv5*)
            echo "ipt2socks@arm-linux-musleabi@generic+v5t+soft_float" ;;
        *arm*)
            echo "ipt2socks@arm-linux-musleabihf@generic+v7a" ;;
        *)
            echo "" ;;
    esac
}

_ASSET_PREFIX_="$(map_arch_to_asset "${os_arch_name}")"
if [ -z "${_ASSET_PREFIX_}" ]; then
    echo "Unsupported architecture: ${os_arch_name}. No matching ipt2socks release asset."
    exit 1
fi
echo "Mapping ${os_arch_name} -> ${_ASSET_PREFIX_}..."

mkdir -p "${_SERVICE_DIR_}"
: >"${_INSTALL_LOG_}"

echo "Downloading latest ${_SERVICE_NAME_} release..."
_FILE_URLS_=""
# Get the list of URLs using the library function
get_github_latest_release_urls_list "zfl9/${_SERVICE_NAME_}" "_FILE_URLS_"

if [ -z "${_FILE_URLS_}" ]; then
    echo "Error: Failed to fetch release URLs from GitHub API."
    echo "Check your network connection or GitHub API rate limits."
    exit 1
fi

# GitHub API URL-encodes '@' as '%40' in browser_download_url.
# Build a regex pattern that matches either '@' or '%40'.
_ASSET_PATTERN_=$(echo "${_ASSET_PREFIX_}" | sed 's/@/(@|%40)/g')

# Strict match at the end of the URL to avoid catching _v2/_v3 or soft_float variants
_FILE_URL_="$(echo "${_FILE_URLS_}" | tr -d '\r' | grep -E "/${_ASSET_PATTERN_}$" | head -n 1)"

if [ -z "${_FILE_URL_}" ]; then
    echo "No release asset found matching suffix '${_ASSET_PREFIX_}'."
    echo "Available assets in the latest release:"
    echo "${_FILE_URLS_}" | tr -d '\r' | sed 's/.*\///' | sed 's/%40/@/g' | sed 's/^/  - /'
    exit 1
fi

# Extract filename and decode %40 back to @ for the local temporary file
_FILE_NAME_="${_FILE_URL_##*/}"
_FILE_NAME_=$(echo "${_FILE_NAME_}" | sed 's/%40/@/g')

get_content "${_FILE_URL_}" "/tmp/${_FILE_NAME_}"
case $? in
    0) ;;
    *) echo "Error downloading ${_FILE_URL_}, exiting."; exit 1 ;;
esac

if ! [ -s "/tmp/${_FILE_NAME_}" ]; then
    echo "Downloaded file /tmp/${_FILE_NAME_} is empty, exiting."; exit 1
fi
echo "Successfully downloaded ${_FILE_NAME_}."

# Install the binary into /opt/ipt2socks/
if [ -x "${_SERVICE_DIR_}/${_SERVICE_EXEC_}" ]; then
    mv -f "${_SERVICE_DIR_}/${_SERVICE_EXEC_}" "${_SERVICE_DIR_}/${_SERVICE_EXEC_}.old"
fi
if ! cp -f "/tmp/${_FILE_NAME_}" "${_SERVICE_DIR_}/${_SERVICE_EXEC_}"; then
    echo "Error copying binary to ${_SERVICE_DIR_}/${_SERVICE_EXEC_}, exiting."; exit 1
fi
chmod +x "${_SERVICE_DIR_}/${_SERVICE_EXEC_}"
"${_SERVICE_DIR_}/${_SERVICE_EXEC_}" --help >/dev/null 2>&1
case $? in
    0) ;;
    *) echo "Installed ${_SERVICE_NAME_} executable not working, exiting."; exit 1 ;;
esac
echo "Successfully installed ${_SERVICE_NAME_} to ${_SERVICE_DIR_}/${_SERVICE_EXEC_}."

# Generate run script on first install; keep existing on updates.
if ! [ -f "${_RUN_SCRIPT_}" ]; then
    cat >"${_RUN_SCRIPT_}" <<EOF
#!/bin/sh
exec "${_SERVICE_DIR_}/${_SERVICE_EXEC_}" \\
    -s "${SOCKS5_ADDR}" \\
    -p "${SOCKS5_PORT}" \\
    -b "${LISTEN_ADDR}" \\
    -l "${LISTEN_PORT}" \\
    ${EXTRA_ARGS}
EOF
    chmod +x "${_RUN_SCRIPT_}"
    echo "Created run script: ${_RUN_SCRIPT_}"
else
    echo "Keeping existing run script: ${_RUN_SCRIPT_}"
fi

# Generate OpenWrt procd init script inside the service directory and symlink it
if [ "${_INIT_SYSTEM_}" != "systemd" ]; then
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
    mkdir -p /etc/init.d
    ln -sf "${_SERVICE_DIR_}/${_SERVICE_NAME_}.init" "/etc/init.d/${_SERVICE_NAME_}"
fi

# Generate systemd unit inside the service directory and symlink it
if [ "${_INIT_SYSTEM_}" = "systemd" ]; then
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
fi

# Restart the service via the detected init system
case "${_INIT_SYSTEM_}" in
    systemd)
        systemctl enable "${_SERVICE_NAME_}"
        systemctl restart "${_SERVICE_NAME_}"
        ;;
    procd)
        /etc/init.d/${_SERVICE_NAME_} enable
        /etc/init.d/${_SERVICE_NAME_} restart 2>/dev/null || /etc/init.d/${_SERVICE_NAME_} start
        ;;
    *)
        echo "No supported init system detected; run ${_RUN_SCRIPT_} manually."
        ;;
esac
echo "${_SERVICE_NAME_CAP_} was (re)installed and started."

# Remove the temporary download
rm -f "/tmp/${_FILE_NAME_}"
