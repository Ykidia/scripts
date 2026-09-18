#!/bin/sh

_SERVICE_NAME_="vpnserver"
_SERVICE_NAME_CAP_="VPN server"
_SERVICE_EXEC_="vpnserver"
_SERVICE_TITLE_="${_SERVICE_NAME_CAP_}"
_SERVICE_DIR_="/opt/${_SERVICE_NAME_}"

mkdir -p ~/sources/SoftEtherVPN
cd ~/sources/SoftEtherVPN
git clone https://github.com/SoftEtherVPN/SoftEtherVPN.git .
git pull
git submodule update --init
rm -rf bin
mkdir -p bin
cd bin
cmake ..
make -j$(nproc || echo 1)
mkdir -p ${_SERVICE_DIR_}

_SERVICE_PROCS_=$(pgrep "\b${_SERVICE_EXEC_}\b")
systemctl disable --now "${_SERVICE_NAME_}"
kill ${_SERVICE_PROCS_} >/dev/null 2>&1

cp -f vpntest vpnserver vpncmd vpnclient vpnbridge libmayaqua.so libcedar.so hamcore.se2 ${_SERVICE_DIR_}/

ln -f -s "${_SERVICE_DIR_}/${_SERVICE_NAME_}.service" "/etc/systemd/system/${_SERVICE_NAME_}.service"
systemctl daemon-reload
systemctl enable "${_SERVICE_NAME_}"
case "${_SERVICE_PROCS_}" in "");; *)
    systemctl start ${_SERVICE_NAME_}
    echo "${_SERVICE_NAME_CAP_} was restarted via systemd."
    ;;
esac
