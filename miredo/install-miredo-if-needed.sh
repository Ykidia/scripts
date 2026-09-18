#!/bin/sh

get_script_dir() { case "$0" in */*) d="${0%/*}" ;; *) d=. ;; esac; CDPATH= cd -- "$d" && pwd -P; }
try_lib_at() { f="${1}/libshell.sh"; [ -r "${f}" ] && . "${f}" 2>/dev/null; }; _THIS_DIR_="$(get_script_dir)"
if ! try_lib_at "${_THIS_DIR_}/.."; then if ! try_lib_at "${_THIS_DIR_}/../common"; then
if ! try_lib_at "${_THIS_DIR_}"; then echo "Error loading library."; exit 1; fi; fi; fi


_COMMON_NAME_="miredo"
_COMMON_NAME_CAP_="Miredo"
_SERVICE_NAME_SERVER_="${_COMMON_NAME_}-server"
_SERVICE_NAME_SERVER_CAP_="${_COMMON_NAME_CAP_}-server"
_SERVICE_CONFDATA_DIR_="/opt/configs"
_USER_HOME_=$(dirname ~/.)

get_country() {
    target="$1"

    case "$target" in
    *[!0-9.]*|*:*)
        ip=$(getent hosts "$target" 2>/dev/null | sed -n 's/ .*//p' | head -1)
        [ -z "$ip" ] && return 1
        ;;
    *)
        ip="$target"
        ;;
    esac

    country=$(get_content "http://ip-api.com/line/$ip?fields=countryCode" 2>/dev/null |tr -d '\r\n')
    case "$country" in "") country=$(get_content "https://ipinfo.io/$ip/country" 2>/dev/null |tr -d '\r\n');; esac
    case "$country" in "") country=$(whois "$ip" 2>/dev/null | sed -n 's/^country:[[:space:]]*//Ip' |head -1);; esac
    case "$country" in "") return 1;; esac

    echo "$country"
}


#
# Check need for the service
#
_CHKNET_OUTPUT_=$(${_THIS_DIR_}/check-network.sh)
_CHKNET_RESULT_=$?
case ${_CHKNET_RESULT_} in
0)
    echo "Two or more IPv4 public addresses + native IPv6 network detected, will install ${_SERVICE_NAME_SERVER_}."
    _SERVICE_NAME_="${_SERVICE_NAME_SERVER_}"
    _SERVICE_NAME_CAP_="${_SERVICE_NAME_SERVER_CAP_}"
    ;;
1)
    echo "Single IPv4 public address + native IPv6 network detected, no need in ${_COMMON_NAME_} client and ${_SERVICE_NAME_SERVER_} is not installable, exiting."
    exit 0
    ;;
2)
    echo "Only IPv4 public network found, will install ${_COMMON_NAME_} client."
    _SERVICE_NAME_="${_COMMON_NAME_}"
    _SERVICE_NAME_CAP_="${_COMMON_NAME_CAP_}"
    ;;
*)
    echo "No suitable network configuration detected for use with ${_COMMON_NAME_}, exiting."
    exit 1
    ;;
esac


#
# Build the service
#
_SERVICE_DIR_="/opt/${_SERVICE_NAME_}"
mkdir -p "${_SERVICE_DIR_}"

_MAKE_RESULT_=1
_BUILD_DIR_="${_USER_HOME_}/sources/${_COMMON_NAME_}"
if mkdir -p "${_BUILD_DIR_}" && cd "${_BUILD_DIR_}"; then
#    rm -rf ./* ./.*
    git clone https://github.com/Ykidia/${_COMMON_NAME_}.git .
    git pull
    git submodule update --init
    if mkdir -p bin && cd bin; then
        _BUILD_DIR_="${_BUILD_DIR_}/bin"
        ../autogen.sh && ../configure --prefix=/ --bindir=${_SERVICE_DIR_} --libexecdir=/opt --sysconfdir=/opt \
            --enable-teredo-client --enable-static --disable-shared \
                && make -j$(nproc || echo 1)
        _MAKE_RESULT_=$?
    fi
fi

case ${_MAKE_RESULT_} in 0);; *)
    echo "Some error(s) occured while making ${_SERVICE_NAME_}, exiting."
    exit 1
    ;;
esac

mkdir -p "${_SERVICE_DIR_}"

v4ips="${_CHKNET_OUTPUT_%;*}"
v4ips="${v4ips##*=}"
v4ip_1="${v4ips%,*}"
_HOST_COUNTRY_="$(get_country "${v4ip_1}")"
case ${_CHKNET_RESULT_} in
0)
    echo "Server country is ${_HOST_COUNTRY_}";;
*)
    echo "Host country is ${_HOST_COUNTRY_}, will try to use server from same country";;
esac


#
# Stop/remove remaining services
#
systemctl disable --now ${_COMMON_NAME_}
systemctl disable --now ${_COMMON_NAME_}-server
apt purge -y ${_COMMON_NAME_} ${_COMMON_NAME_}-server


#
# Create/edit the service's user
#

_SERVICE_USER_="${_SERVICE_NAME_}"
_SERVICE_HOME_="/var/run/${_SERVICE_NAME_}"
_NOGROUP_GID_=65534
_SHELL_NOLOGIN_="/usr/sbin/nologin"

[ -x "$_SHELL_NOLOGIN_" ] || _SHELL_NOLOGIN_="/sbin/nologin"
[ -x "$_SHELL_NOLOGIN_" ] || _SHELL_NOLOGIN_="/bin/false"

if grep -q "^${_SERVICE_USER_}:" /etc/passwd; then
    echo "User '${_SERVICE_USER_}' already exists. Verifying primary group..."
    CURRENT_GID=$(grep "^${_SERVICE_USER_}:" /etc/passwd | cut -d: -f4)
    if [ "$CURRENT_GID" != "$_NOGROUP_GID_" ]; then
        sed -i "s/^\(${_SERVICE_USER_}:[^:]*:[^:]*:\)[0-9]*\(.*\)/\1${_NOGROUP_GID_}\2/" /etc/passwd
        echo "Existing user '${_SERVICE_USER_}' corrected successfully."
    fi
else
    adduser --system --no-create-home --home "${_SERVICE_HOME_}" \
            --shell "${_SHELL_NOLOGIN_}" --ingroup nogroup "${_SERVICE_USER_}" 2>/dev/null || \
    adduser -S -D -H -h "${_SERVICE_HOME_}" -s "${_SHELL_NOLOGIN_}" \
            -G nogroup "${_SERVICE_USER_}" 2>/dev/null || \
    {
        _NEXT_UID_=$(cut -d: -f3 /etc/passwd | sort -n | tail -1)
        _NEXT_UID_=$((_NEXT_UID_ + 1))
        echo "${_SERVICE_USER_}:x:${_NEXT_UID_}:${_NOGROUP_GID_}::${_SERVICE_HOME_}:${_SHELL_NOLOGIN_}" >> /etc/passwd
    }
    echo "User '${_SERVICE_USER_}' created successfully."
fi

mkdir -p "${_SERVICE_HOME_}"
chown "${_SERVICE_USER_}:${_NOGROUP_GID_}" "${_SERVICE_HOME_}"
chmod 0755 "${_SERVICE_HOME_}"


#
# Install and configure the service
#
cp -f "${_BUILD_DIR_}/${_SERVICE_NAME_}" "${_SERVICE_DIR_}/"
cp -f "${_THIS_DIR_}/${_SERVICE_NAME_}.service" "${_SERVICE_DIR_}/"
case ${_CHKNET_RESULT_} in
0)
    case $? in 0);; *)
        cat >"${_SERVICE_DIR_}/${_SERVICE_NAME_}.service" <<EOF
[Unit]
Description=Teredo IPv6 tunneling server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${_SERVICE_DIR_}/${_SERVICE_NAME_} -c ${_SERVICE_DIR_}/${_SERVICE_NAME_}.conf -u ${_SERVICE_USER_} -f
Restart=on-failure
RestartSec=10
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=no
ProtectSystem=strict
ReadWritePaths=/run /var/log/${_COMMON_NAME_}

[Install]
WantedBy=multi-user.target
EOF
    ;;
    esac
    v4ip_2="${v4ips##*,}"
    cat >"${_SERVICE_DIR_}/${_SERVICE_NAME_}.conf" <<EOF
# Server primary IPv4 address. ${_SERVICE_NAME_CAP_} will open UDP port 3544 on this IPv4 address and the next one.
ServerBindAddress ${v4ip_1}
# Server secondary IPv4 address, if it is different from primary+1.
ServerBindAddress2 ${v4ip_2}
EOF
    ;;
2)
    case $? in 0);; *)
        cat >"${_SERVICE_DIR_}/${_SERVICE_NAME_}.service" <<EOF
[Unit]
Description=Teredo IPv6 tunneling
After=network.target

[Service]
ExecStartPre=${_SERVICE_DIR_}/${_SERVICE_NAME_}-checkconf -f ${_SERVICE_DIR_}/${_SERVICE_NAME_}.conf
ExecStart=${_SERVICE_DIR_}/${_SERVICE_NAME_} -c ${_SERVICE_DIR_}/${_SERVICE_NAME_}.conf -u ${_SERVICE_USER_} -f
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
    ;;
    esac
    cp -f "${_BUILD_DIR_}/${_COMMON_NAME_}-checkconf" "${_SERVICE_DIR_}/"
    cp -f "${_BUILD_DIR_}/${_COMMON_NAME_}-privproc" "${_SERVICE_DIR_}/"
    cp -f "${_BUILD_DIR_}/client-hook" "${_SERVICE_DIR_}/"
    chmod +x "${_SERVICE_DIR_}/client-hook"

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
    srv_1=""
    srv_2=""
    while read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        case "${line}" in "") continue;; esac
        server1="${line%+*}"
        server2="${line##*+}"
        server1="${server1#"${server1%%[![:space:]]*}"}"
        server1="${server1%"${server1##*[![:space:]]}"}"
        server2="${server2#"${server2%%[![:space:]]*}"}"
        server2="${server2%"${server2##*[![:space:]]}"}"
        case "${server1}" in "");; *)
            srv_1="${server1}"
            srv_2="${server2}"
            _SERVER_COUNTRY_="$(get_country "${server1}")"
            case "${_SERVER_COUNTRY_}" in "${_HOST_COUNTRY_}") break;; esac
            ;;
        esac
    done <"${_SERVICE_CONFDATA_}"
    case "${srv_1}" in "")
        # default server(s) if custom list is empty
        # srv_1="debian-miredo.progsoc.org" or "teredo.trex.fi" or "teredo.ginzado.ne.jp" or "win10.ipv6.microsoft.com"
        srv_1="teredo.iks-jena.de"
        srv_2="teredo2.iks-jena.de"
        _SERVER_COUNTRY_="$(get_country "${server1}")"
        ;;
    esac
    echo "Server country is ${_SERVER_COUNTRY_}."
    _REMARK_SYMBOL_="#"
    cat >"${_SERVICE_DIR_}/${_SERVICE_NAME_}.conf" <<EOF
#!${_SERVICE_DIR_}/${_SERVICE_NAME_} -f -c
# Name of the network tunneling interface.
InterfaceName teredo
# Server primary IPv4 address.
ServerAddress ${srv_1}
# Server secondary IPv4 address, if it is different from primary+1.
${_REMARK_SYMBOL_%${srv_2:+${_REMARK_SYMBOL_}}}ServerAddress2 ${srv_2}
# Log
SyslogFacility local7
SyslogLevel info
EOF
    ;;
esac

ln -f -s "${_SERVICE_DIR_}/${_SERVICE_NAME_}.service" "/etc/systemd/system/${_SERVICE_NAME_}.service"
systemctl daemon-reload

cd "${_THIS_DIR_}"
mkdir -p "/var/log/${_COMMON_NAME_}"

systemctl enable ${_SERVICE_NAME_}

