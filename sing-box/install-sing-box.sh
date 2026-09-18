#!/bin/sh

get_script_dir() { case "${0}" in *"/"*) d="${0%/*}";; *) d=.;; esac; CDPATH="" cd -- "${d}" && pwd -P; }
try_lib_at() { f="${1}/libshell.sh"; [ -r "${f}" ] && . "${f}" 2>/dev/null; }; _THIS_DIR_="$(get_script_dir)"
if ! try_lib_at "${_THIS_DIR_}/.."; then if ! try_lib_at "${_THIS_DIR_}/../common"; then
if ! try_lib_at "${_THIS_DIR_}"; then echo "Error loading library."; exit 1; fi; fi; fi


_SERVICE_NAME_="sing-box"
_SERVICE_NAME_CAP_="Sing-box"
_SERVICE_EXEC_="sing-box"
_SERVICE_TITLE_="${_SERVICE_NAME_CAP_} server"
_SERVICE_DIR_="/opt/${_SERVICE_NAME_}"
_SERVICE_CONFDATA_DIR_="/opt/configs"
_SERVICE_CONFIG_DIR_="${_SERVICE_DIR_}"
_SERVICE_LOG_DIR_="${_SERVICE_DIR_}/logs"
_INSTALL_LOG_="/tmp/install-${_SERVICE_NAME_}.log"
_FC_PEM_="fullchain.pem"
_PK_PEM_="privkey.pem"


case "${os_is_openwrt}" in
0)
    _DOWNLOAD_DIR_="${_SERVICE_DIR_}"
    case "${os_arch_name}" in
    *"86_64")
        _DISTRIB_ARCH_="linux-amd64";;
    *)
        _DISTRIB_ARCH_="${os_arch_name}";;
    esac
    rm -f ${_DOWNLOAD_DIR_}/*${_DISTRIB_ARCH_}.tar.* 2>/dev/null
    ;;
*)
    _DOWNLOAD_DIR_="/tmp"
    _SERVICE_CONFIG_DIR_="/etc/${_SERVICE_NAME_}"
    _SERVICE_LOG_DIR_="/tmp"
    _IS_OPKG_=$(apk stats --version >/dev/null 2>&1 && echo 0 || echo 1)
    _OPENWRT_PKG_EXT_=$(case ${_IS_OPKG_} in 0) echo apk;; *) echo ipk;; esac)
    _DISTRIB_ARCH_="openwrt_${os_arch_name}"
    rm -f ${_DOWNLOAD_DIR_}/*${_DISTRIB_ARCH_}.${_OPENWRT_PKG_EXT_} 2>/dev/null
    ;;
esac
_SERVICE_CERTS_DIR_="${_SERVICE_CONFIG_DIR_}/certs"
_SERVICE_FC_PEM_="${_SERVICE_CERTS_DIR_}/${_FC_PEM_}"
_SERVICE_PK_PEM_="${_SERVICE_CERTS_DIR_}/${_PK_PEM_}"
_SERVICE_CONFIG_="${_SERVICE_CONFIG_DIR_}/config.json"
mkdir -p "${_SERVICE_DIR_}"
: >"${_INSTALL_LOG_}"


#
# First, generate config for the service
#
_RC_=1
_SERVICE_CONFDATA_="${_SERVICE_CONFDATA_DIR_}/${_SERVICE_NAME_}.conf"
case ${os_is_openwrt} in 0);; *)
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
    _SERVICE_DIR_="/usr/bin"
    ;;
esac
_DEFAULT_INPORT_=12443
_DEFAULT_PORT_=
_CONFIG_OK_=0
if ${_SERVICE_DIR_}/${_SERVICE_EXEC_} check -c "${_SERVICE_CONFIG_}"; then
    _CONFIG_OK_=1
fi

case ${_CONFIG_OK_} in 0)
    echo "${_SERVICE_NAME_CAP_} configuration ${_SERVICE_CONFIG_} does not exist or invalid, creating default..."
    cat >"${_SERVICE_CONFIG_}" <<EOF
{
  "log": {
    "level": "debug",
    "output": "${_SERVICE_LOG_DIR_}/${_SERVICE_NAME_}.log",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive-tls",
      "listen": "0.0.0.0",
      "listen_port": ${_DEFAULT_INPORT_},
      "users": [
    {
      "username": "user",
      "password": "secret"
    }
      ],
      "tls": {
    "enabled": true,
    "server_name": "domain",
    "alpn": ["h2", "http/1.1"],
    "certificate_path": "${_SERVICE_FC_PEM_}",
    "key_path": "${_SERVICE_PK_PEM_}"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": { "final": "direct" }
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
    # config string: "domain[:inport]@user=secret[,port]"
    #   domain - domain to listen on, inport - bind to 0.0.0.0:inport, user/secret - naive creds, port - upstream socks5 127.0.0.1:port
    # (adapted from "[inport,]user=secret@domain[:port]" for naiveproxy)
    counter=$((counter + 1))
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "${line}" in "") continue;; esac
    case "${line}" in *"@"*"="*);; *) continue;; esac
    domaininport="${line%@*}"
    domain="${domaininport%:*}"
    inport=0
    case "${domaininport}" in *":"*)
        inport="${domaininport##*:}"
        inport="${inport#"${inport%%[![:space:]]*}"}"
        inport="${inport%"${inport##*[![:space:]]}"}"
        case ${inport} in "") inport=0;; esac
        case ${inport} in
        *[!0-9]*)
            inport=0;;
        *)
            inport=$((inport));;
        esac
        ;;
    esac
    case ${inport} in 0) inport=${_DEFAULT_INPORT_};; esac
    usersecretport="${line##*@}"
    usersecret="${usersecretport%,*}"
    port=0
    case "${usersecretport}" in *","*)
        port="${usersecretport##*,}"
        port="${port#"${port%%[![:space:]]*}"}"
        port="${port%"${port##*[![:space:]]}"}"
        case ${port} in "") port=0;; esac
        case ${port} in *[!0-9]*) continue;;
        *)
            port=$((port));;
        esac
        ;;
    esac
    user="${usersecret%=*}"
    secret="${usersecret##*=}"
    user="${user#"${user%%[![:space:]]*}"}"
    user="${user%"${user##*[![:space:]]}"}"
    case "${user}" in "") continue;; esac
    secret="${secret#"${secret%%[![:space:]]*}"}"
    secret="${secret%"${secret##*[![:space:]]}"}"
    case "${secret}" in "") continue;; esac
    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    case "${domain}" in "") continue;; esac
#    # "listen_port": ${_DEFAULT_INPORT_}
#    sed -i "s|\"listen_port\"[[:space:]]*:[[:space:]]*[0-9]+|\"listen_port\": ${inport}|g" "${_SERVICE_CONFIG_}"
#    # "username": "user"
#    sed -i "s|\"username\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"username\": \"${user}\"|g" "${_SERVICE_CONFIG_}"
#    # "password": "secret"
#    sed -i "s|\"password\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"password\": \"${secret}\"|g" "${_SERVICE_CONFIG_}"
#    # "server_name": "domain"
#    sed -i "s|\"server_name\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"server_name\": \"${domain}\"|g" "${_SERVICE_CONFIG_}"
#    # "outbounds": [ ... ]
#    while grep -Eq "[[:space:]]*\"route\"[[:space:]]*:[[:space:]]*\{[[:space:]]*\"rules\"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{[^\}]*\}" "${_SERVICE_CONFIG_}"; do
#        sed -Ei "s|[[:space:]]*\"route\"[[:space:]]*:[[:space:]]*\{[[:space:]]*\"rules\"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{[^\}]*\}[[:space:]]*\,?|\"route\":{\"rules\":[|g" "${_SERVICE_CONFIG_}"
#    done
#    sed -Ei "s|[[:space:]]*\"route\"[[:space:]]*:[[:space:]]*\{[^\}]*\}\,?||g" "${_SERVICE_CONFIG_}"
#    case ${port} in
#    0)
#        echo "Using direct outbound."
#        sed -Ei "s|\"outbounds\"[[:space:]]*:[[:space:]]*\[[^\]]*\]|\"outbounds\": [ { \"type\": \"direct\", \"tag\": \"direct\" } ], \"route\": { \"final\": \"direct\" }|g" "${_SERVICE_CONFIG_}"
#        ;;
#    *)
#        tagname="upstream-socks5"
#        echo "Using ${tagname} outbound."
#        sed -Ei "s|\"outbounds\"[[:space:]]*:[[:space:]]*\[[^\]]*\]|\"outbounds\": [ { \"type\": \"socks\", \"tag\": \"${tagname}\", \"server\": \"127.0.0.1\", \"server_port\": \"${port}\" } ], \"route\": { \"final\": \"${tagname}\" }|g" "${_SERVICE_CONFIG_}"
#        ;;
#    esac
    case ${port} in
    0)
        echo "Using direct outbound."
        ;;
    *)
        tagname="upstream-socks5"
        echo "Using ${tagname} outbound."
        ;;
    esac
    awk -v RS='^$' -v inport="${inport}" -v user="${user}" -v secret="${secret}" \
        -v domain="${domain}" -v port="${port}" -v tagname="${tagname:-upstream-socks5}" \
    '
    {
        # * listen_port
        gsub(/"listen_port"[[:space:]]*:[[:space:]]*[0-9]+/, "\"listen_port\": " inport)
        # * username, password, server_name
        gsub(/"username"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"username\": \"" user "\"")
        gsub(/"password"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"password\": \"" secret "\"")
        gsub(/"server_name"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"server_name\": \"" domain "\"")
        # - route.rules
        while (gsub(/[[:space:]]*"route"[[:space:]]*:[[:space:]]*\{[[:space:]]*"rules"[[:space:]]*:[[:space:]]*\[[[:space:]]*\{[^}]*\}[[:space:]]*,?/,
            "\"route\":{\"rules\":[")) {}
        # - route
        gsub(/[[:space:]]*"route"[[:space:]]*:[[:space:]]*\{[^}]*\},?/, "")
        # * outbounds + route
        if (port == 0 || port == "") {
        gsub(/"outbounds"[[:space:]]*:[[:space:]]*\[[^\]]*\]/,
             "\"outbounds\": [ { \"type\": \"direct\", \"tag\": \"direct\" } ], \"route\": { \"final\": \"direct\" }")
        } else {
        gsub(/"outbounds"[[:space:]]*:[[:space:]]*\[[^\]]*\]/,
             "\"outbounds\": [ { \"type\": \"socks\", \"tag\": \"" tagname "\", \"server\": \"127.0.0.1\", \"server_port\": " port " } ], \"route\": { \"final\": \"" tagname "\" }")
        }
        print
    }
    ' "${_SERVICE_CONFIG_}" >"${_SERVICE_CONFIG_}.tmp" && mv "${_SERVICE_CONFIG_}.tmp" "${_SERVICE_CONFIG_}"

    _EXTERNAL_CERTS_DIR_="/etc/letsencrypt/live/${domain}"
    mkdir -p "${_SERVICE_CERTS_DIR_}"
    if [ -s ${_EXTERNAL_CERTS_DIR_}/${_FC_PEM_} ] && [ -s ${_EXTERNAL_CERTS_DIR_}/${_PK_PEM_} ]; then
        ln -s "${_EXTERNAL_CERTS_DIR_}/${_FC_PEM_}" "${_SERVICE_FC_PEM_}"
        ln -s "${_EXTERNAL_CERTS_DIR_}/${_PK_PEM_}" "${_SERVICE_PK_PEM_}"
    else
        if [ -s "${_SERVICE_FC_PEM_}" ] && [ -s "${_SERVICE_PK_PEM_}" ]; then
            echo "Cannot link to certbot's certificate, but something found in ${_SERVICE_CERTS_DIR_}/, will use it."
        else
            echo "Quering our external/public IP address..."
            _PUBLIC_IP_=
            for getipurl in "https://api.ipify.org"; do
                _PUBLIC_IP_="$(uclient-fetch -qO- ${getipurl} 2>/dev/null)"
                case $? in 0);; *)
                    _PUBLIC_IP_="$(wget -q -O- ${getipurl} 2>/dev/null)"
                    case $? in 0);; *)
                        _PUBLIC_IP_="$(curl -s ${getipurl} 2>/dev/null)"
                        ;;
                    esac
                    ;;
                esac
            done
            case ${os_is_openwrt} in
            0)
                echo "Certificate for ${domain} not found."
                command -v certbot >/dev/null || echo "Please install certbot."
                echo "Use certbot to issue a certificate for ${domain}, like this:"
                echo "  certbot certonly --standalone -d ${domain}"
                ;;
            *)
                # TODO: output some friendly message here for OpenWrt
                ;;
            esac
            _LAN_IP_="$(ip -o -4 a show br-lan 2>/dev/null |tr -s " \t" " " |cut -d " " -f4 |cut -d "/" -f1)"
            echo "Now will create new selfsigned certificate."
            _SAN_IP_TEXT_=
            case "${_PUBLIC_IP_}" in "");; *)
                _SAN_IP_TEXT_=",IP:${_PUBLIC_IP_}";;
            esac
            case "${_LAN_IP_}" in ""|"${_PUBLIC_IP_}");; *)
                _SAN_IP_TEXT_="${_SAN_IP_TEXT_},IP:${_LAN_IP_}";;
            esac
            openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "${_SERVICE_PK_PEM_}" -out "${_SERVICE_FC_PEM_}" \
                -days 365 -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}${_SAN_IP_TEXT_}" >/dev/null
            if [ $? -eq 0 ] && [ -s "${_SERVICE_FC_PEM_}" ] && [ -s "${_SERVICE_PK_PEM_}" ]; then
                echo "Successfully created selfsigned certificate."
            else
                echo "Error creating selfsigned certificate, exiting."
                exit 1
            fi
        fi
    fi
    _RC_=0
    # only single credentials/data set supported for now
    break
done <"${_SERVICE_CONFDATA_}"
case ${_RC_} in
0)
    echo "Successfully (re)inserted credentials found in ${_SERVICE_CONFDATA_} into ${_SERVICE_NAME_} configuration ${_SERVICE_CONFIG_}."
    ;;
*)
    echo "No credentials found in ${_SERVICE_CONFDATA_}, exiting."
    exit 1
    ;;
esac


#
# Second, download and extract latest service exec version
#
get_github_latest_release_urls_list "SagerNet/${_SERVICE_NAME_}" "_FILE_URLS_"
case ${os_is_openwrt} in
0)
    _FILE_URL_="$(echo "${_FILE_URLS_}" |grep -F "${_DISTRIB_ARCH_}-glibc")" ###'''
    _FILE_NAME_="${_FILE_URL_##*/}"
    case "${_FILE_URL_}" in "")
        _FILE_URL_="$(echo "${_FILE_URLS_}" |grep -F "${_DISTRIB_ARCH_}-musl")" ###'''
        _FILE_NAME_="${_FILE_URL_##*/}"
        ;;
    esac
    ;;
*)
    mkdir -p "/etc/${_SERVICE_NAME_}"
    _FILE_URL_="$(echo "${_FILE_URLS_}" |grep -F "${_DISTRIB_ARCH_}.${_OPENWRT_PKG_EXT_}")" ###'''
    _FILE_NAME_="${_FILE_URL_##*/}"
    ;;
esac

get_content "${_FILE_URL_}" "${_DOWNLOAD_DIR_}/${_FILE_NAME_}"
case $? in 0);; *)
    echo "Error downloading latest ${_SERVICE_NAME_} release from ${_FILE_URL_}, exiting."
    exit 1
    ;;
esac
if ! [ -s "${_DOWNLOAD_DIR_}/${_FILE_NAME_}" ]; then
    echo "Latest ${_SERVICE_NAME_} release downloadable, but file ${_DOWNLOAD_DIR_}/${_FILE_NAME_} is not writeable, exiting."
    exit 1
fi
echo "Successfully downloaded ${_SERVICE_NAME_} release to ${_DOWNLOAD_DIR_}/${_FILE_NAME_}."

_SERVICE_PROCS_=$(pgrep "\b${_SERVICE_EXEC_}\b")
_XFILE_NAME_="${_SERVICE_EXEC_}"
case ${os_is_openwrt} in
0)
    _XFILE_PATH_="$(tar -tf "${_DOWNLOAD_DIR_}/${_FILE_NAME_}" |grep "${_XFILE_NAME_}$")"
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

    if ! tar -xf "${_DOWNLOAD_DIR_}/${_FILE_NAME_}" --transform='s|.*/||' -C "${_SERVICE_DIR_}" "${_XFILE_PATH_}" 2>/dev/null; then
        if tar -xf "${_DOWNLOAD_DIR_}/${_FILE_NAME_}" -O "${_XFILE_PATH_}" >"${_SERVICE_DIR_}/${_XFILE_NAME_}" 2>/dev/null; then
            chmod +x "${_SERVICE_DIR_}/${_XFILE_NAME_}" 2>/dev/null
        fi
    fi
    case $? in 0);; *)
        echo "Error extracting ${_SERVICE_NAME_} executable to ${_SERVICE_DIR_}/${_XFILE_NAME_}, exiting."
        exit 1
        ;;
    esac
    ${_SERVICE_DIR_}/${_XFILE_NAME_} --help >/dev/null 2>&1
    case $? in 0);; *)
        echo "Extracted ${_SERVICE_NAME_} executable to ${_SERVICE_DIR_}/${_XFILE_NAME_} not working, exiting."
        exit 1
        ;;
    esac
    echo "Successfully extracted ${_SERVICE_NAME_} executable to ${_SERVICE_DIR_}/${_XFILE_NAME_}."
    ;;
*)
    case "${_SERVICE_PROCS_}" in "");; *)
        /etc/init.d/${_SERVICE_NAME_} stop 2>/dev/null
        kill ${_SERVICE_PROCS_} >/dev/null 2>&1
        ;;
    esac
    case ${_IS_OPKG_} in
    0)
        apk del --no-interactive --no-progress --no-network --force-non-repository --rdepends \
            ${_SERVICE_NAME_} >/dev/null 2>&1
        apk add --no-interactive --no-progress --no-network --force-non-repository --force-overwrite --allow-untrusted \
            "${_DOWNLOAD_DIR_}/${_FILE_NAME_}" >/dev/null 2>&1
        ;;
    *)
        opkg remove ${_SERVICE_NAME_} >/dev/null 2>&1
        opkg install "${_DOWNLOAD_DIR_}/${_FILE_NAME_}" >/dev/null 2>&1
        ;;
    esac
    case $? in 0);; *)
        echo "Error reinstalling package ${_DOWNLOAD_DIR_}/${_FILE_NAME_}, exiting."
        exit 1
        ;;
    esac
    ;;
esac


#
# Finally, install the service
#
case ${os_is_openwrt} in
0)
    systemctl disable --now ${_SERVICE_NAME_}
    kill $(pgrep "\b${_SERVICE_EXEC_}\b") >/dev/null 2>&1
    if ! cp -f "${_THIS_DIR_}/${_SERVICE_NAME_}.service" ${_SERVICE_DIR_}/ >/dev/null 2>&1; then
        cat >"${_SERVICE_DIR_}/${_SERVICE_NAME_}.service" <<EOF
[Unit]
Description=${_SERVICE_TITLE_}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
WorkingDirectory=${_SERVICE_DIR_}
ExecStart=${_SERVICE_DIR_}/${_SERVICE_EXEC_} run -c ${_SERVICE_CONFIG_}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_DAC_OVERRIDE CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_DAC_OVERRIDE CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    fi
    ln -f -s "${_SERVICE_DIR_}/${_SERVICE_NAME_}.service" "/etc/systemd/system/${_SERVICE_NAME_}.service"
    setcap 'cap_net_bind_service,cap_dac_override+ep' "${_SERVICE_DIR_}/${_SERVICE_EXEC_}"
    mkdir -p "${_SERVICE_LOG_DIR_}"
    chown -R nobody:nogroup "${_SERVICE_DIR_}"
    systemctl daemon-reload
    systemctl enable ${_SERVICE_NAME_}
    case "${_SERVICE_PROCS_}" in "");; *)
        systemctl start ${_SERVICE_NAME_}
        echo "${_SERVICE_NAME_CAP_} was restarted via systemd."
        ;;
    esac
    ;;
*)
    /etc/init.d/${_SERVICE_NAME_} enable
    case "${_SERVICE_PROCS_}" in "");; *)
        /etc/init.d/${_SERVICE_NAME_} start
        echo "${_SERVICE_NAME_CAP_} was restarted via procd."
        ;;
    esac
    ;;
esac

case "${_OLD_XFILE_PATH_}" in "");; *)
    if rm -f "${_OLD_XFILE_PATH_}" >/dev/null 2>&1; then
        echo "Successfully removed old ${_SERVICE_NAME_} executable ${_OLD_XFILE_PATH_}."
    fi
    ;;
esac
