#!/bin/sh

get_script_dir() { case "${0}" in *"/"*) d="${0%/*}";; *) d=.;; esac; CDPATH="" cd -- "${d}" && pwd -P; }
try_lib_at() { f="${1}/libshell.sh"; [ -r "${f}" ] && . "${f}" 2>/dev/null; }; _THIS_DIR_="$(get_script_dir)"
if ! try_lib_at "${_THIS_DIR_}/.."; then if ! try_lib_at "${_THIS_DIR_}/../common"; then
if ! try_lib_at "${_THIS_DIR_}"; then echo "Error loading library."; exit 1; fi; fi; fi


_SERVICE_NAME_="mtproxy"
_SERVICE_NAME_CAP_="MTProxy"
_SERVICE_EXEC_="telego"
_SERVICE_TITLE_="${_SERVICE_NAME_CAP_} server"
_SERVICE_DIR_="/opt/${_SERVICE_NAME_}"
_SERVICE_CONFDATA_DIR_="/opt/configs"
_SERVICE_CONFIG_DIR_="${_SERVICE_DIR_}"
_SERVICE_CONFIG_="${_SERVICE_CONFIG_DIR_}/${_SERVICE_EXEC_}.conf"
_SERVICE_LOG_DIR_="${_SERVICE_DIR_}/logs"
_INSTALL_LOG_="/tmp/install-${_SERVICE_NAME_}.log"


#
# Create config if needed
#
_DEFAULT_INPORT_=8443
_CONFIG_OK_=0
if [ -s "${_SERVICE_CONFIG_}" ]; then
    # TODO: really check config
    _CONFIG_OK_=1
fi

case ${_CONFIG_OK_} in 0)
    echo "${_SERVICE_NAME_CAP_} configuration ${_SERVICE_CONFIG_} does not exist or invalid, creating default..."
    cat >"${_SERVICE_CONFIG_}" <<EOF
[general]
bind-to = "0.0.0.0:${_DEFAULT_INPORT_}"
proxy-protocol = true
max-connections-per-ip = 0
handshake-timeout = "10s"
max-ips-per-user = 0

[secrets]

[tls-fronting]
mask-host = "okko.tv"

#[upstream]
#socks5 = "127.0.0.1:1089"
EOF
    if ! [ -s "${_SERVICE_CONFIG_}" ]; then
        echo "Error creating default ${_SERVICE_NAME_} configuration ${_SERVICE_CONFIG_}, exiting."
        exit 1
    fi
    ;;
esac


#
# Download and build
#
mkdir -p ~/sources/telego
cd ~/sources/telego
git clone https://github.com/Scratch-net/telego.git .
git pull
git submodule update --init
make clean
make build


#
# Install the service
#
_SERVICE_PROCS_=$(pgrep "\b${_SERVICE_EXEC_}\b")
systemctl disable --now ${_SERVICE_NAME_}
kill $(pgrep "\b${_SERVICE_EXEC_}\b") >/dev/null 2>&1

cp -f ${_SERVICE_EXEC_} ${_SERVICE_DIR_}/

if ! cp -f "${_THIS_DIR_}/${_SERVICE_NAME_}.service" ${_SERVICE_DIR_}/ >/dev/null 2>&1; then
    cat >"${_SERVICE_DIR_}/${_SERVICE_NAME_}.service" <<EOF
[Unit]
Description=${_SERVICE_TITLE_}
After=network.target

[Service]
Type=simple
WorkingDirectory=${_SERVICE_DIR_}
ExecStart=${_THIS_DIR_}/run-${_SERVICE_NAME_}.sh
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
fi

ln -f -s "${_SERVICE_DIR_}/${_SERVICE_NAME_}.service" "/etc/systemd/system/${_SERVICE_NAME_}.service"
systemctl daemon-reload
systemctl enable ${_SERVICE_NAME_}
case "${_SERVICE_PROCS_}" in "");; *)
    systemctl start ${_SERVICE_NAME_}
    echo "${_SERVICE_NAME_CAP_} was restarted via systemd."
    ;;
esac
