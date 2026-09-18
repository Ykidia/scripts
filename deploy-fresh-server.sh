#!/bin/bash

apt install -y aptitude cron htop mc systemd-zram-generator zstd sslh sshfs iptables-persistent ipset gnutls-bin dnsmasq certbot haproxy \
wget curl net-tools dnsutils cmake build-essential dh-autoreconf golang git pkg-config \
gettext libjudy-dev libncurses-dev libsodium-dev libssl-dev zlib1g-dev libreadline-dev

mkdir /root/sources
mkdir /mnt/sshfs

# Setup hostname in /etc/hosts, /etc/hostname, and by hostname command

# Setup network using migrate-to-ifupdown.sh (IPv6 only by hands)

# Install rules in /etc/iptables, setup dnsmasq

# Install scripts in /opt/scripts

# Install services using /opt/scripts/*/install-*.sh

# Install cron tasks in /var/spool/cron/crontabs

# Setup /etc/sysctl.d
