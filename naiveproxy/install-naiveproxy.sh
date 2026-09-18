#!/bin/sh

get_script_dir() { case "${0}" in *"/"*) d="${0%/*}";; *) d=.;; esac; CDPATH="" cd -- "${d}" && pwd -P; }
try_lib_at() { f="${1}/libshell.sh"; [ -r "${f}" ] && . "${f}" 2>/dev/null; }; _THIS_DIR_="$(get_script_dir)"
if ! try_lib_at "${_THIS_DIR_}/.."; then if ! try_lib_at "${_THIS_DIR_}/../common"; then
if ! try_lib_at "${_THIS_DIR_}"; then echo "Error loading library."; exit 1; fi; fi; fi


_SERVICE_NAME_="naiveproxy"
_SERVICE_NAME_CAP_="Naiveproxy"
_SERVICE_EXEC_="naive"
_SERVICE_TITLE_="${_SERVICE_NAME_CAP_} Server"
_SERVICE_DIR_="/opt/${_SERVICE_NAME_}"
_SERVICE_CONFIG_DIR_="${_SERVICE_DIR_}"
_SERVICE_CONFDATA_DIR_="/opt/configs"
_INSTALL_LOG_="/tmp/install-${_SERVICE_NAME_}.log"


case "${os_is_openwrt}" in
0)
    case "${os_arch_name}" in
    *"86_64")
        _DISTRIB_ARCH_="linux-x64";;
    *)
        _DISTRIB_ARCH_="${os_arch_name}";;
    esac
    ;;
*)
    _DISTRIB_ARCH_="openwrt-${os_arch_name}"
    ;;
esac
mkdir -p "${_SERVICE_DIR_}"
: >"${_INSTALL_LOG_}"


#
# First of all, generate config for the service
#
_RC_=1
_SERVICE_CONFDATA_="${_SERVICE_CONFDATA_DIR_}/${_SERVICE_NAME_}.conf"
if ! [ -s "${_SERVICE_CONFDATA_}" ]; then
    _SERVICE_CONFDATA_="${_SERVICE_DIR_}/${_SERVICE_NAME_}.conf"
    if ! [ -s "${_SERVICE_CONFDATA_}" ]; then
        _SERVICE_CONFDATA_="/etc/${_SERVICE_NAME_}/${_SERVICE_NAME_}.conf"
        if ! [ -s "${_SERVICE_CONFDATA_}" ]; then
            echo "Data file ${_SERVICE_NAME_}.conf not found, exiting."
            exit 1
        fi
    fi
fi
_SERVICE_CONFIG_="${_SERVICE_DIR_}/client.json"
_DEFAULT_INPORT_=1089
_DEFAULT_PORT_=443
_CONFIG_OK_=0
if [ -s "${_SERVICE_CONFIG_}" ]; then
    grep -qE "\"listen\"[[:space:]]*:[[:space:]]*\[[[:space:]]*\".*\"[[:space:]]*\]" ${_SERVICE_CONFIG_} \
        && grep -qE "\"proxy\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" ${_SERVICE_CONFIG_} \
            && _CONFIG_OK_=1
fi

case ${_CONFIG_OK_} in 0)
    echo "${_SERVICE_NAME_CAP_} configuration ${_SERVICE_CONFIG_} does not exist or invalid, creating default..."
    cat >"${_SERVICE_CONFIG_}" <<EOF
{
  "listen": ["socks://0.0.0.0:${_DEFAULT_INPORT_}", "socks://[::]:${_DEFAULT_INPORT_}"],
  "proxy": "https://user:secret@host:port",
  "quic": false,
  "log": ""
}
EOF
    if ! [ -s "${_SERVICE_CONFIG_}" ]; then
        echo "Error creating default ${_SERVICE_NAME_} configuration ${_SERVICE_CONFIG_}, exiting."
        exit 1
    fi
    ;;
esac

counter=0
while read -r line; do
    counter=$((counter + 1))
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "${line}" in "") continue;; esac
    case "${line}" in *"="*"@"*);; *) continue;; esac
    username="${line%=*}"
    inport=0
    case "${username}" in *","*)
        inport="${username%,*}"
        inport="${inport#"${inport%%[![:space:]]*}"}"
        inport="${inport%"${inport##*[![:space:]]}"}"
        username="${username##*,}"
        case ${inport} in "") inport=${_DEFAULT_INPORT_};; esac
        case ${inport} in
        *[!0-9]*)
            inport=${_DEFAULT_INPORT_};;
        *)
            inport=$((inport));;
        esac
        ;;
    esac
    secrethostport="${line##*=}"
    invalid=1
    case "${secrethostport}" in *"@"*)
        secret="${secrethostport%@*}"
        hostport="${secrethostport##*@}"
        case "${hostport}" in *":"*)
            port="${hostport##*:}"
            port="${port#"${port%%[![:space:]]*}"}"
            port="${port%"${port##*[![:space:]]}"}"
            case ${port} in "") port=${_DEFAULT_PORT_};; esac
            case "${port}" in *[!0-9]*);;
            *)
                invalid=0
                host="${hostport%:*}"
                port=$((port))
                ;;
            esac
            ;;
        esac
        ;;
    esac
    case ${invalid} in 0);; *) continue;; esac
    username="${username#"${username%%[![:space:]]*}"}"
    username="${username%"${username##*[![:space:]]}"}"
    case "${username}" in "") continue;; esac
    secret="${secret#"${secret%%[![:space:]]*}"}"
    secret="${secret%"${secret##*[![:space:]]}"}"
    case "${secret}" in "") continue;; esac
    host="${host#"${host%%[![:space:]]*}"}"
    host="${host%"${host##*[![:space:]]}"}"
    case "${host}" in "") continue;; esac
    newproxy="https://${username}:${secret}@${host}:${port}"
    newvalue="$(printf '%s' "${newproxy}" |sed 's/[&\\/"]/\\&/g')"
    sed -i "s|\"proxy\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"proxy\": \"${newvalue}\"|g" "${_SERVICE_CONFIG_}"
    case ${inport} in 0);; *)
        newvalue="$(printf '%s' "[\"socks://0.0.0.0:${inport}\", \"socks://[::]:${inport}\"]" |sed 's/[&\\/"]/\\&/g')"
        sed -i "s|\"listen\"[[:space:]]*:[[:space:]]*\[[[:space:]]*\".*\"[[:space:]]*\]|\"listen\": ${newvalue}|g" "${_SERVICE_CONFIG_}"
        ;;
    esac
    _RC_=0
    # only single credentials set supported for now
    break
done <"${_SERVICE_CONFDATA_}"
case ${_RC_} in
0)
    echo "Successfully (re)inserted credentials found in ${_SERVICE_CONFDATA_} into ${_SERVICE_NAME_} configuration ${_SERVICE_CONFIG_}."
    ;;
*)
    echo "No credentials found in \"${_SERVICE_CONFDATA_}\", exiting."
    exit 1
    ;;
esac


#
# Second, download and extract latest service exec version
#
rm -rf ${_SERVICE_DIR_}/*${_DISTRIB_ARCH_}.tar.*

_XFILE_NAME_="${_SERVICE_EXEC_}"
get_github_latest_release_urls_list "klzgrad/${_SERVICE_NAME_}" "_FILE_URLS_"
_FILE_URL_="$(echo "${_FILE_URLS_}" |grep -F "${_DISTRIB_ARCH_}-static")" ###'''
case "${_FILE_URL_}" in "")
    _FILE_URL_="$(echo "${_FILE_URLS_}" |grep -F "${_DISTRIB_ARCH_}")" ###'''
    ;;
esac
case "${_FILE_URL_}" in "")
    echo "Cannot get URL to download latest ${_SERVICE_NAME_} release, exiting."
    exit 1
    ;;
esac

##case "${_FILE_URL_}" in "");; *)

_FILE_NAME_="${_FILE_URL_##*/}"
get_content "${_FILE_URL_}" "${_SERVICE_DIR_}/${_FILE_NAME_}"
case $? in 0);; *)
    echo "Error downloading latest ${_SERVICE_NAME_} release from ${_FILE_URL_}, exiting."
    exit 1
    ;;
esac
if ! [ -s "${_SERVICE_DIR_}/${_FILE_NAME_}" ]; then
    echo "Latest ${_SERVICE_NAME_} release downloadable, but file ${_SERVICE_DIR_}/${_FILE_NAME_} is not writeable, exiting."
    exit 1
fi
echo "Successfully downloaded ${_SERVICE_NAME_} release ${_SERVICE_DIR_}/${_FILE_NAME_}."

_XFILE_PATH_="$(tar -tf "${_SERVICE_DIR_}/${_FILE_NAME_}" |grep "${_XFILE_NAME_}$")"
case $? in 0);; *)
    echo "${_SERVICE_NAME_CAP_} executable not found, exiting."
    exit 1
    ;;
esac

_OLD_XFILE_PATH_=
if [ -x "${_SERVICE_DIR_}/${_XFILE_NAME_}" ]; then
    _OLD_XFILE_PATH_="${_SERVICE_DIR_}/${_XFILE_NAME_}.0"
    mv -f "${_SERVICE_DIR_}/${_XFILE_NAME_}" "${_OLD_XFILE_PATH_}"
fi

if ! tar -xf "${_SERVICE_DIR_}/${_FILE_NAME_}" --transform='s|.*/||' -C "${_SERVICE_DIR_}" "${_XFILE_PATH_}" 2>>"${_INSTALL_LOG_}"; then
    if tar -xf "${_SERVICE_DIR_}/${_FILE_NAME_}" -O "${_XFILE_PATH_}" >"${_SERVICE_DIR_}/${_XFILE_NAME_}" 2>>"${_INSTALL_LOG_}"; then
        chmod +x "${_SERVICE_DIR_}/${_XFILE_NAME_}" 2>>"${_INSTALL_LOG_}"
    fi
fi
case $? in 0);; *)
    echo "Error extracting ${_SERVICE_NAME_} executable to ${_SERVICE_DIR_}/${_XFILE_NAME_}, exiting."
    exit 1
    ;;
esac
${_SERVICE_DIR_}/${_XFILE_NAME_} --help >/dev/null 2>>"${_INSTALL_LOG_}"
case $? in 0);; *)
    echo "Extracted ${_SERVICE_NAME_} executable to ${_SERVICE_DIR_}/${_XFILE_NAME_} not working, exiting."
    exit 1
    ;;
esac
echo "Successfully extracted ${_SERVICE_NAME_} executable to ${_SERVICE_DIR_}/${_XFILE_NAME_}."

##;; esac


#
# Finally, install the service
#
_SERVICE_PROCS_=$(pgrep "\b${_SERVICE_EXEC_}\b")
case ${os_is_openwrt} in
0)
    systemctl disable --now ${_SERVICE_NAME_}
    kill $(pgrep "\b${_SERVICE_EXEC_}\b") >>"${_INSTALL_LOG_}" 2>&1
    if ! cp -f "${_THIS_DIR_}/${_SERVICE_NAME_}.service" ${_SERVICE_DIR_}/ >>"${_INSTALL_LOG_}" 2>&1; then
        cat >"${_SERVICE_DIR_}/${_SERVICE_NAME_}.service" <<EOF
[Unit]
Description=${_SERVICE_TITLE_}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root

ExecStart=${_SERVICE_DIR_}/${_SERVICE_EXEC_} ${_SERVICE_CONFIG_}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadOnlyPaths=/etc/letsencrypt
ReadWritePaths=/tmp /run

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
    ;;
*)
    case "${_SERVICE_PROCS_}" in "");; *)
        /etc/init.d/${_SERVICE_NAME_} stop 2>>"${_INSTALL_LOG_}"
        kill ${_SERVICE_PROCS_} >>"${_INSTALL_LOG_}" 2>&1
        ;;
    esac
    cat >"/etc/init.d/${_SERVICE_NAME_}" <<EOF
#!/bin/sh /etc/rc.common
#

START=99
USE_PROCD=1

service_init="/etc/init.d/${_SERVICE_NAME_}"
service_exec="${_SERVICE_DIR_}/${_SERVICE_EXEC_}"
service_config="${_SERVICE_CONFIG_}"
service_pidfile="/var/run/${_SERVICE_NAME_}.pid"

boot()
{
    [ -s "\${service_pidfile}" ] && >"\${service_pidfile}"
    rc_procd start_service
}

start_service()
{
    procd_open_instance "${_SERVICE_NAME_}"
    procd_set_param command "\${service_exec}" "\${service_config}"
    procd_set_param pidfile "\${service_pidfile}"
    procd_set_param limits nofile 65536
    procd_set_param limits nproc 4096
    procd_set_param limits memlock 65536
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

restart()
{
    rc_procd stop_service
    rc_procd start_service
}
EOF
    /etc/init.d/${_SERVICE_NAME_} enable
    case "${_SERVICE_PROCS_}" in "");; *)
        /etc/init.d/${_SERVICE_NAME_} start
        echo "${_SERVICE_NAME_CAP_} was restarted via procd."
        ;;
    esac
    ;;
esac

case "${_OLD_XFILE_PATH_}" in "");; *)
    if rm -f "${_OLD_XFILE_PATH_}" >>"${_INSTALL_LOG_}" 2>&1; then
        echo "Successfully removed old ${_SERVICE_NAME_} executable ${_OLD_XFILE_PATH_}."
    fi
    ;;
esac
