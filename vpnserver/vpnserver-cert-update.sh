#! /bin/bash

get_script_dir() { case "$0" in */*) d="${0%/*}" ;; *) d=. ;; esac; CDPATH= cd -- "$d" && pwd -P; }
HELPER_DIR="$(get_script_dir)"
HELPER_SCRIPT="run-with-free-ports.sh"
if [ -s "${HELPER_DIR}/${HELPER_SCRIPT}" ]; then
    HELPER_SCRIPT="${HELPER_DIR}/${HELPER_SCRIPT}"
else
    HELPER_DIR="$(realpath ${HELPER_DIR}/..)"
    if [ -s "${HELPER_DIR}/${HELPER_SCRIPT}" ]; then
        HELPER_SCRIPT="${HELPER_DIR}/${HELPER_SCRIPT}"
    else
        echo "Helper script "${HELPER_SCRIPT}" not found."
        exit 1
    fi
fi
[ -n "${1}" ] || {
    echo "Server hub not specified!"
    exit 1
}
[ -n "${2}" ] || {
    echo "Server password not specified!"
    exit 1
}
PATH=/usr/bin:/usr/sbin:/bin:/sbin:/etc/init.d
SRV_PATH=/opt/vpnserver
SRV_EXEC=vpnserver
HOST_NAME=$(hostname)
CERT_DIR=/etc/letsencrypt/live/${HOST_NAME}
SRV_HUB="${1}"
SRV_PASS="${2}"

"${HELPER_SCRIPT}" --command "certbot renew --standalone" || {
    echo "Error trying to renew certificate!" >&2
    exit 1
}

pgrep ${SRV_EXEC} || /etc/init.d/${SRV_EXEC} start
PWD_SAVE=$(pwd)
cd ${SRV_PATH}
./vpncmd /server localhost:5555 /password:${SRV_PASS} /adminhub:${SRV_HUB} /cmd ServerCertSet /LOADCERT:${CERT_DIR}/cert.pem /LOADKEY:${CERT_DIR}/privkey.pem && printf "
 *** VPNCMD for ${HOST_NAME} OK!

"
cd ${PWD_SAVE}

