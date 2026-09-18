#!/bin/bash

dpkg --configure -a
apt update
apt-get --allow-releaseinfo-change update
#aptitude update
apt-get upgrade -y
aptitude upgrade -y
apt full-upgrade -y
aptitude install -f -y
apt autoremove -y
apt-get autoclean -y
apt-get clean -y
#apt-get update
aptitude update
dpkg -l | awk '/^rc/ {print $2}' | xargs -r dpkg --purge

