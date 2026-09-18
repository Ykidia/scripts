#!/bin/sh

_VPNSERVER_DIR_=/opt/vpnserver

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
mkdir -p ${_VPNSERVER_DIR_}

systemctl disable --now vpnserver

cp -f vpntest vpnserver vpncmd vpnclient vpnbridge libmayaqua.so libcedar.so hamcore.se2 ${_VPNSERVER_DIR_}/

ln -f -s ${_VPNSERVER_DIR_}/vpnserver.service /etc/systemd/system/vpnserver.service
systemctl daemon-reload
systemctl enable vpnserver
